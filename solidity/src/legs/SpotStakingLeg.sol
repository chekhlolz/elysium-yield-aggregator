// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Router.sol";
import "../interfaces/IStakingPool.sol";
import "../interfaces/IPriceOracle.sol";

/**
 * @title SpotStakingLeg
 * @notice Wraps direct HYPE staking on HyperEVM (validator-adjacent
 *         staking, distinct from the kHYPE LST wrapper). Same
 *         allocation pattern as KHYPELeg but a different venue.
 *
 * Flow:
 *   allocateTo(amount) : USDC --router--> HYPE --pool.stake--> rewardHYPE.
 *   harvest()          : sweeps any USDC sitting in this leg.
 *   reduceFrom(amount) : rewardHYPE --pool.unstake--> creditAt --> USDC.
 *
 * Venue: HyperEVM direct staking pool.
 *
 * Known limitations:
 *   - `UNBONDING_PERIOD` is a hard-coded hint constant (per spec). The
 *     pool's live `unbondingPeriod()` is the source of truth; the
 *     constant is documentation and a test upper bound.
 *   - Router slippage is 0; production needs a slippage-bps param.
 */
contract SpotStakingLeg is IYieldLeg {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_HISTORY = 16;
    /// @dev Unbonding hint — direct HYPE staking on HyperEVM is
    ///      typically ~24h. Documentation / test upper bound only.
    uint256 public constant UNBONDING_PERIOD = 24 * 3600;

    // Round-3 reentrancy guard — pool/router are external and untrusted.
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    address public immutable owner;
    IERC20Minimal public immutable usdc;
    IERC20Minimal public immutable hype;
    IERC20Router  public immutable router;
    IStakingPool  public immutable pool;
    IPriceOracle  public immutable oracle;

    uint256 public allocatedUsd;
    uint256 public rewardHypeBalance;
    uint256 public latestApyBps;

    // TODO: fixedApyBps config fallback — remove once the live oracle
    //       is wired on Elysium.
    uint256 public fixedApyBps;

    struct Observation {
        uint64 ts;
        uint256 apyBps;
    }
    Observation[] public history;

    // NOTE: Allocated / Reduced / Harvested events are inherited from
    // IYieldLeg — Solidity does not permit re-declaring them here.

    constructor(
        address _usdc,
        address _hype,
        address _router,
        address _pool,
        address _oracle,
        uint256 _fixedApyBps
    ) {
        owner = msg.sender;
        usdc   = IERC20Minimal(_usdc);
        hype   = IERC20Minimal(_hype);
        router = IERC20Router(_router);
        pool   = IStakingPool(_pool);
        oracle = IPriceOracle(_oracle);
        fixedApyBps = _fixedApyBps;
        latestApyBps = _fixedApyBps;
    }

    // ---- IYieldLeg ----

    function name() external pure returns (string memory) {
        return "SpotStakingLeg";
    }

    function expectedApy() public view returns (uint256) {
        if (address(oracle) == address(0)) return latestApyBps;
        try oracle.getApy("HYPE") returns (uint256 a) {
            return a;
        } catch {
            return latestApyBps;
        }
    }

    function apyHistory() external view returns (uint256[] memory out) {
        uint256 n = history.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = history[i].apyBps;
    }

    /**
     * KI-1 (Option A, DESIGN_KI1_UNIT_RECONCILE): rewardHypeBalance is
     * tracked in HYPE units (18 dec) -- the pool.exchangeRate() factor
     * is folded in at the boundary (allocateTo).
     */
    function currentValue() external view returns (uint256) {
        uint256 v = 0;
        if (rewardHypeBalance > 0) {
            uint256 price = _hypePriceUsdc();
            v = (rewardHypeBalance * price) / 1_000_000;
        }
        v += usdc.balanceOf(address(this));
        return v;
    }

    function allocateTo(uint256 usdAmount) external nonReentrant returns (uint256) {
        require(msg.sender == owner, "not owner");
        require(usdAmount > 0, "zero");

        // KI-1 (Option A): convert USDC -> HYPE at the live oracle
        // price, and track the HYPE-equivalent for the on-book balance.
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");

        uint256 hypeIn = router.swapExactUSDCForToken(address(hype), usdAmount);
        require(hypeIn > 0, "router returned 0");

        hype.safeApprove(address(pool), hypeIn);
        _stake(hypeIn);

        rewardHypeBalance += hypeIn;
        allocatedUsd += usdAmount;
        _recordApy(expectedApy());
        emit Allocated(usdAmount, allocatedUsd);
        return usdAmount;
    }

    /** Direct staking accrues via exchange rate — no claim(); sweep only. */
    function harvest() external nonReentrant {
        require(msg.sender == owner, "not owner");
        uint256 u = usdc.balanceOf(address(this));
        if (u > 0) {
            if (allocatedUsd >= u) allocatedUsd -= u; else allocatedUsd = 0;
            usdc.safeTransfer(owner, u);
            emit Harvested(u);
        }
        _recordApy(expectedApy());
    }

    function reduceFrom(uint256 usdAmount) external nonReentrant returns (uint256 returnedUsd) {
        require(msg.sender == owner, "not owner");

        // KI-1 (Option A): convert USDC -> HYPE at the live oracle
        // price, then convert HYPE -> stake tokens via the pool's
        // current exchangeRate(). Call pool.unstake with the stake-
        // token amount -- never with the raw USDC amount.
        require(usdAmount > 0, "bad amount");
        require(rewardHypeBalance > 0, "bad amount");
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");
        // usdAmount is 6-dec, price is 6-dec, HYPE is 18-dec:
        //   hypeAmount = (usdAmount * 1e12) / price
        uint256 hypeAmount = (usdAmount * 1_000_000_000_000) / price;
        require(rewardHypeBalance >= hypeAmount, "bad amount");

        rewardHypeBalance -= hypeAmount;

        // Convert HYPE amount to stake tokens via the live pool rate.
        uint256 rate = pool.exchangeRate();
        require(rate > 0, "pool rate is 0");
        uint256 stakeTokenAmount = (hypeAmount * rate) / 1_000_000_000_000_000_000;
        require(stakeTokenAmount > 0, "zero stake amount");

        _unstake(stakeTokenAmount);

        uint256 period = pool.unbondingPeriod();
        if (period == 0) {
            uint256 hypeOut = pool.creditUnbonded(address(this), stakeTokenAmount, address(this));
            if (hypeOut > 0) {
                hype.safeApprove(address(router), hypeOut);
                uint256 u = router.swapExactTokenForUSDC(address(hype), hypeOut);
                usdc.safeTransfer(owner, u);
                returnedUsd = u;
            }
        }

        allocatedUsd = usdAmount <= allocatedUsd
            ? allocatedUsd - usdAmount
            : 0;

        emit Reduced(usdAmount, allocatedUsd);
    }

    // ---- Owner helpers ----

    /** Sweep unbonded HYPE and swap to USDC. */
    function claimPending(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) return;
        uint256 hypeOut = pool.creditUnbonded(address(this), amount, address(this));
        if (hypeOut > 0) {
            hype.safeApprove(address(router), hypeOut);
            uint256 u = router.swapExactTokenForUSDC(address(hype), hypeOut);
            usdc.safeTransfer(owner, u);
        }
    }

    /** Governance: change the fixed-APY fallback.
     *  Round-4 KI-4 fix: refresh `latestApyBps` immediately when
     *  `oracle` is unwired, so `expectedApy()` doesn't serve a stale
     *  value until the next `harvest()`.
     */
    function setFixedApyBps(uint256 v) external onlyOwner {
        fixedApyBps = v;
        if (address(oracle) == address(0)) latestApyBps = v;
    }

    // ---- Internal flow (per task spec) ----

    function _stake(uint256 hypeAmount) internal {
        pool.stake(address(hype), hypeAmount);
    }

    function _unstake(uint256 amount) internal {
        pool.unstake(address(this), amount);
    }

    // ---- Internals ----

    function _hypePriceUsdc() internal view returns (uint256) {
        if (address(oracle) == address(0)) return 0;
        try oracle.priceOf("HYPE") returns (uint256 p) { return p; }
        catch { return 0; }
    }

    function _recordApy(uint256 a) internal {
        if (history.length >= MAX_HISTORY) {
            for (uint256 i = 0; i < MAX_HISTORY - 1; i++) {
                history[i] = history[i + 1];
            }
            history[MAX_HISTORY - 1] = Observation({
                ts: uint64(block.timestamp),
                apyBps: a
            });
        } else {
            history.push(Observation({
                ts: uint64(block.timestamp),
                apyBps: a
            }));
        }
        latestApyBps = a;
    }
}
