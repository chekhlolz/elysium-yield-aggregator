// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Router.sol";
import "../interfaces/IStakingPool.sol";
import "../interfaces/IPriceOracle.sol";

/**
 * @title KHYPELeg
 * @notice Wraps the kHYPE liquid-staking token on HyperCore. Yield is
 *         represented by the pool's exchange rate (1 kHYPE worths more
 *         HYPE over time) — no claim() is needed to receive rewards.
 *
 * Flow:
 *   allocateTo(amount) : USDC --router--> HYPE --pool.stake--> kHYPE.
 *   harvest()          : sweeps any USDC sitting in this leg.
 *   reduceFrom(amount) : kHYPE --pool.unstake--> creditAt --creditUnbonded-->
 *                        HYPE --router--> USDC (returned to aggregator).
 *
 * Venue: HyperCore kHYPE staking pool.
 *
 * Known limitations:
 *   - Router slippage is fixed at 0 for minOut; production needs a
 *     slippage-bps param tuned per venue.
 *   - The unbonding period may be non-zero; while unbonding is pending,
 *     reduceFrom() returns 0 and the aggregator must call `claimPending`
 *     once the clock has run.
 */
contract KHYPELeg is IYieldLeg {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_HISTORY = 16;

    // Round-3 reentrancy guard — router/pool are external and untrusted.
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
    uint256 public khypeBalance;
    uint256 public latestApyBps;

    // TODO: fixedApyBps config fallback — remove once the live oracle is
    //       wired on Elysium. Used whenever oracle == address(0).
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
        return "KHYPELeg";
    }

    function expectedApy() public view returns (uint256) {
        if (address(oracle) == address(0)) return latestApyBps;
        try oracle.getApy("kHYPE") returns (uint256 a) {
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
     * KI-1 (Option A, DESIGN_KI1_UNIT_RECONCILE): khypeBalance is now
     * tracked in HYPE units (18 dec) -- the pool.exchangeRate() factor
     * is folded in at the boundary (allocateTo), so the valuation
     * math collapses to `hype * price`.
     */
    function currentValue() external view returns (uint256) {
        uint256 v = 0;
        if (khypeBalance > 0) {
            uint256 price = _hypePriceUsdc();
            v = (khypeBalance * price) / 1e6;
        }
        v += usdc.balanceOf(address(this));
        return v;
    }

    function allocateTo(uint256 usdAmount) external nonReentrant returns (uint256) {
        require(msg.sender == owner, "not owner");
        require(usdAmount > 0, "zero");

        // KI-1 (Option A): convert USDC -> HYPE at the live oracle
        // price, and track the HYPE-equivalent for the on-book balance.
        // currentValue() then collapses to `khypeBalance * price`.
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");
        uint256 hypeEquivalent = (usdAmount * 1e18) / price;

        uint256 hypeIn = router.swapExactUSDCForToken(address(hype), usdAmount);
        require(hypeIn > 0, "router returned 0");

        hype.safeApprove(address(pool), hypeIn);
        pool.stake(address(hype), hypeIn);

        khypeBalance += hypeEquivalent;
        allocatedUsd += usdAmount;

        _recordApy(expectedApy());
        emit Allocated(usdAmount, allocatedUsd);
        return usdAmount;
    }

    /** kHYPE accrues through exchange rate — no claim(); only USDC sweep. */
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
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");
        uint256 hypeAmount = (usdAmount * 1e18) / price;
        require(khypeBalance >= hypeAmount, "bad amount");

        khypeBalance -= hypeAmount;

        // Convert HYPE amount to stake tokens via the live pool rate.
        uint256 rate = pool.exchangeRate();
        require(rate > 0, "pool rate is 0");
        uint256 stakeTokenAmount = (hypeAmount * rate) / 1e18;
        require(stakeTokenAmount > 0, "zero stake amount");

        pool.unstake(address(this), stakeTokenAmount);

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
     *  Round-4 KI-4 fix: also refresh `latestApyBps` so `expectedApy()`
     *  reflects the new value immediately instead of waiting for the
     *  next `harvest()` / `allocateTo()`. Only safe when `oracle` is
     *  unwired (zero address) — otherwise the oracle read is still
     *  authoritative and we shouldn't poison the cache.
     */
    function setFixedApyBps(uint256 v) external onlyOwner {
        fixedApyBps = v;
        if (address(oracle) == address(0)) latestApyBps = v;
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
