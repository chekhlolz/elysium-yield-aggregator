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
 *   - Router slippage is enforced via `slippageBps` against the oracle
 *     price AFTER the swap returns (round-8 hardening); the router
 *     interface itself still has no `minOut` parameter.
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

    // Round-8 hardening: slippage ceiling enforced against the oracle
    // price AFTER `router.swapExactUSDCForToken` returns. The router
    // interface has no `minOut` param, so we bound slippage on the
    // return value.
    //
    // 0 disables the guard (used by tests that pin exact fills);
    // 100 (1%) is the recommended production default.
    uint256 public slippageBps;

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
        uint256 _fixedApyBps,
        uint256 _slippageBps
    ) {
        require(_slippageBps <= BPS_DENOM, "slippageBps > 100%");
        owner = msg.sender;
        usdc   = IERC20Minimal(_usdc);
        hype   = IERC20Minimal(_hype);
        router = IERC20Router(_router);
        pool   = IStakingPool(_pool);
        oracle = IPriceOracle(_oracle);
        fixedApyBps = _fixedApyBps;
        latestApyBps = _fixedApyBps;
        slippageBps = _slippageBps;
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
     * KI-1 (b) rate-tracking (DESIGN_KI1_RATE_TRACKING, Option A2):
     * rewardHypeBalance is tracked in STAKE-TOKEN units (18 dec) — the
     * pool's exchangeRate() factor is applied at the boundary
     * (allocateTo) via a pool.balanceOf before/after delta, so that
     *   rewardHypeBalance == pool.balanceOf(address(this), address(this))
     * holds by construction. currentValue() re-applies the live rate
     * before multiplying by the USDC/HYPE price, so the valuation
     * tracks the pool's mark-to-market value of the same stake-token
     * position.
     */
    function currentValue() external view returns (uint256) {
        uint256 v = 0;
        if (rewardHypeBalance > 0) {
            uint256 price = _hypePriceUsdc();
            uint256 rate  = pool.exchangeRate();
            // rewardHypeBalance is 18-dec stake tokens, rate is 18-dec
            // (stake->HYPE), price is 6-dec USDC/HYPE.
            // v_6dec = rewardHypeBalance * rate * price / 1e36
            v = (rewardHypeBalance * rate * price)
                / 1_000_000_000_000_000_000_000_000_000_000_000_000;
        }
        v += usdc.balanceOf(address(this));
        return v;
    }

    function allocateTo(uint256 usdAmount) external nonReentrant returns (uint256) {
        require(msg.sender == owner, "not owner");
        require(usdAmount > 0, "zero");

        // KI-1 (b) rate-tracking (DESIGN_KI1_RATE_TRACKING, Option A2):
        // rewardHypeBalance is now in STAKE-TOKEN units. Capture the
        // pool's own stake-token balance before and after pool.stake()
        // and add the DELTA -- never the raw router return, never the
        // pool's total. Exact by construction.
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");

        uint256 hypeIn = router.swapExactUSDCForToken(address(hype), usdAmount);
        require(hypeIn > 0, "router returned 0");

        // Round-8 hardening: bound slippage against the oracle price.
        if (slippageBps > 0) {
            uint256 hypeMin = (usdAmount * 1_000_000_000_000_000_000
                               * (BPS_DENOM - slippageBps))
                              / (price * BPS_DENOM);
            require(hypeIn >= hypeMin, "slippage exceeded");
        }

        // KI-1 (b) Option A2: capture stake-token delta before/after
        // pool.stake. rewardHypeBalance is a stake-token count,
        // matching the unit the pool actually mints.
        uint256 stakeBefore = pool.balanceOf(address(this), address(this));

        hype.safeApprove(address(pool), hypeIn);
        _stake(hypeIn);

        uint256 stakeAfter = pool.balanceOf(address(this), address(this));
        require(stakeAfter >= stakeBefore, "pool mint regressed");
        rewardHypeBalance += (stakeAfter - stakeBefore);
        allocatedUsd += usdAmount;
        _recordApy(expectedApy());
        emit Allocated(usdAmount, allocatedUsd);
        return usdAmount;
    }

    /**
     * Direct staking accrues via exchange rate — no claim(); sweep only.
     *
     * Round-8 fix: harvest() does NOT decrement `allocatedUsd`. The
     * realised USDC yield is swept to the owner, but the vault's
     * principal ledger tracks the underlying HYPE position, not the
     * realised reward. Decrementing would drift the aggregator's
     * `_allocatedTotal` downward by the yield amount on the next
     * `harvestFromAllLegs()` refresh (see §5.3 / §9.2 of
     * DESIGN_KI1_UNIT_RECONCILE).
     */
    function harvest() external nonReentrant {
        require(msg.sender == owner, "not owner");
        uint256 u = usdc.balanceOf(address(this));
        if (u > 0) {
            usdc.safeTransfer(owner, u);
            emit Harvested(u);
        }
        _recordApy(expectedApy());
    }

    function reduceFrom(uint256 usdAmount) external nonReentrant returns (uint256 returnedUsd) {
        require(msg.sender == owner, "not owner");

        // KI-1 (b) rate-tracking (DESIGN_KI1_RATE_TRACKING, Option A2):
        // rewardHypeBalance is a stake-token count. Compute the
        // stake-token amount to burn BEFORE decrementing the ledger,
        // so the pool's book and the leg's book stay in the same
        // unit at all times.
        require(usdAmount > 0, "bad amount");
        require(rewardHypeBalance > 0, "bad amount");
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");
        // usdAmount is 6-dec, price is 6-dec, HYPE is 18-dec:
        //   hypeAmount = (usdAmount * 1e18) / price
        uint256 hypeAmount = (usdAmount * 1_000_000_000_000_000_000) / price;

        // Convert HYPE amount to stake tokens via the live pool rate.
        // Under the pool's convention (DESIGN_KI1_RATE_TRACKING §1):
        //   1 stake token = exchangeRate()/1e18 HYPE.
        // Inverting: stakeTokenAmount = (hypeAmount * 1e18) / rate,
        // which is the inverse of `pool.creditUnbonded`'s
        // `hypeOut = stakeAmount * rate / 1e18` and keeps
        // currentValue() = stake * rate * price / 1e36 consistent
        // with what a real pool redemption would return.
        //
        // NOTE: DESIGN_KI1_RATE_TRACKING §5 wrote this as
        // `(hypeAmount * rate) / 1e18`; that direction inverts the
        // pool's credit path. See the doc's §11 follow-up.
        uint256 rate = pool.exchangeRate();
        require(rate > 0, "pool rate is 0");
        uint256 stakeTokenAmount = (hypeAmount * 1_000_000_000_000_000_000) / rate;
        require(stakeTokenAmount > 0, "zero stake amount");
        require(rewardHypeBalance >= stakeTokenAmount, "bad amount");

        // KI-1 (b): decrement the stake-token counter, not the raw
        // HYPE input -- matches what pool.unstake burns.
        rewardHypeBalance -= stakeTokenAmount;

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

    /** Governance: change the slippage ceiling in basis points.
     *  0 disables the guard entirely (used in tests with exact-fill
     *  mocks); 100 (1%) is the recommended production default.
     */
    function setSlippageBps(uint256 v) external onlyOwner {
        require(v <= BPS_DENOM, "slippageBps > 100%");
        slippageBps = v;
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
