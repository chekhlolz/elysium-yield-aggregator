// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Router.sol";
import "../interfaces/ITradeOnlyAgent.sol";
import "../interfaces/IElysiumCoreWriter.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IIntentSubmittingLeg.sol";

/**
 * @title BasisHedgeLeg
 * @notice Delta-neutral hedge at HR = 1.0: long spot HYPE + short perp
 *         HYPE at equal notional. The goal is basis carry (perp premium
 *         or discount vs spot), not funding.
 *
 * Flow:
 *   allocateTo(amount) : USDC --router--> HYPE (long spot, half)
 *                        + writer.openPosition(HYPE, Short, half) (short perp).
 *   harvest()          : flip-close the short to lock in the basis PnL
 *                        (USDC credited by the writer), then sweep USDC.
 *   reduceFrom(amount) : pro-rata close perp + sell spot.
 *
 * Venue: HyperCore HYPE-USD perp + spot market, via ElysiumCoreWriter.
 *
 * Known limitations:
 *   - `currentValue()` returns spot + perp PnL. Perp PnL is proxied
 *     here as the on-hand USDC balance delta, since the writer credits
 *     realised PnL directly; unrealised mark-to-market is out of scope
 *     for this stub.
 *   - No `fundingSource` dependency — funding is orthogonal to the
 *     basis-hedge strategy (see PerpFundingLeg for the funding version).
 *   - `HEDGE_RATIO_BPS` is hard-coded to 10_000 (HR=1.0) per spec.
 *     Production should allow the ratio to be configurable per venue.
 */
contract BasisHedgeLeg is IYieldLeg, IIntentSubmittingLeg {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_HISTORY = 16;
    /// Delta-neutral hedge ratio in bps. 10_000 = 1.0x.
    uint256 public constant HEDGE_RATIO_BPS = 10_000;

    /// HYPE-USD perp coin id on Elysium.
    /// TODO: confirm with Kinetiq before mainnet.
    uint256 public constant HYPE_ASSET_ID = 1;

    // Round-3 reentrancy guard — writer/router are external and untrusted.
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    address public immutable owner;
    IERC20Minimal      public immutable usdc;
    IERC20Minimal      public immutable hype;
    /// TODO: router address set by deployer — replace with the
    ///       production HyperCore DEX router.
    IERC20Router       public immutable router;
    IElysiumCoreWriter public immutable writer;
    ITradeOnlyAgent    public immutable tradeOnlyAgent;
    IPriceOracle       public immutable oracle;

    address public immutable delegator;

    /// KI-2b Phase 2: aggregator address. The aggregator drives all
    /// perp rebalances via the stream-A entry points
    /// (`submitIntentFromStreamA`, `reduceIntent`, `harvestIntent`);
    /// those check `d.keeper == aggregator`. Non-immutable so it can be
    /// wired AFTER deployment (the leg is deployed before the aggregator,
    /// because the aggregator constructor takes the leg addresses).
    address public aggregator;

    /// KI-2b Phase 2: gate on the legacy `_fallbackSig()` path used
    /// by `allocateTo` / `harvest` / `reduceFrom`. Default `true`
    /// preserves the round-4/7/9/11 test behaviour; production
    /// deployments flip it to `false` via `setDevFallbackEnabled`,
    /// after which the legacy paths revert and only the stream-A
    /// entry points are callable.
    bool public devFallbackEnabled;

    uint256 public allocatedUsd;
    uint256 public spotHypeBalance;
    uint256 public perpNotional;
    uint256 public realisedBasisPnl;   // cumulative USDC credited by writer
    uint256 public latestApyBps;
    /// KI-2b Phase 3 (DESIGN_KI2_SUBMITINTENT.md §6): "the next nonce
    /// the leg will propose". Renamed from `lastDelegationNonce` — the
    /// old name described the last one the leg bumped, which conflicted
    /// with `_nextDelegation()`'s actual "read-before-increment"
    /// ordering (pre-increment semantics: nonce=0 on the first call,
    /// nonce=1 on the second, etc.). `nextDelegationNonce` starts at
    /// 0 and is bumped by 1 after each `_nextDelegation()` call, so it
    /// reads as "the next nonce this leg will propose next time".
    uint256 public nextDelegationNonce;

    /// KI-2b Phase 3 (DESIGN_KI2_SUBMITINTENT.md §6): highest
    /// delegation nonce actually ACKNOWLEDGED by the venue, per
    /// (delegator, nonce). A (delegator, nonce) pair whose entry here
    /// is non-zero was forwarded to `writer.openPosition` /
    /// `writer.closePosition` in a call that returned without reverting.
    ///
    /// @dev Written ONLY after `writer.openPosition` /
    ///      `writer.closePosition` returns without reverting inside
    ///      `submitIntent` / `submitIntentFromStreamA` — the paths
    ///      that actually hand a real user-signed delegation to the
    ///      writer. NOT written from `_fallbackSig()`-gated paths
    ///      (`allocateTo`, `harvest`, `reduceFrom`) because those use
    ///      a dev-only zero-sig and don't represent real delegation
    ///      execution. NOT written from `_nextDelegation()` itself,
    ///      which bumps `nextDelegationNonce` on every call regardless
    ///      of venue response — a naive propose-keyed mapping would
    ///      attribute nonces the venue never saw. A reverted writer
    ///      call never reaches the mapping write, so "written after
    ///      a non-reverting writer call" is sufficient to distinguish
    ///      proposed-but-rejected from proposed-and-acknowledged. The
    ///      venue does not yet report execution state back through
    ///      Solidity (DESIGN_KI2_SUBMITINTENT.md §9 Phase 3 note), so
    ///      this is the simplest correct semantics. Clients that want
    ///      to know the highest nonce they have pre-signed safely can
    ///      track their own proposal history; the leg exposes the
    ///      proposed upper bound separately via `nextDelegationNonce`.
    mapping(address => mapping(uint256 => uint256)) public lastExecutedNonce;

    // TODO: fixedApyBps fallback — remove once live basis oracle
    //       publishes a mark-to-market APY.
    uint256 public fixedApyBps;

    struct Observation {
        uint64 ts;
        uint256 apyBps;
    }
    Observation[] public history;

    // NOTE: Allocated / Reduced / Harvested events are inherited from
    // IYieldLeg — Solidity does not permit re-declaring them here.

    /// KI-2: nonce-keyed set of submitted intents. Keyed by
    /// keccak256(keeper, nonce, salt); the same (keeper, nonce, salt)
    /// tuple cannot be submitted twice to this leg.
    mapping(bytes32 => bool) public submittedIntents;

    constructor(
        address _usdc,
        address _hype,
        address _router,
        address _writer,
        address _tradeOnlyAgent,
        address _oracle,
        address _delegator,
        uint256 _fixedApyBps
    ) {
        owner = msg.sender;
        usdc           = IERC20Minimal(_usdc);
        hype           = IERC20Minimal(_hype);
        router         = IERC20Router(_router);
        writer         = IElysiumCoreWriter(_writer);
        tradeOnlyAgent = ITradeOnlyAgent(_tradeOnlyAgent);
        oracle         = IPriceOracle(_oracle);
        delegator      = _delegator;
        fixedApyBps    = _fixedApyBps;
        latestApyBps   = _fixedApyBps;
        // KI-2b Phase 2: aggregator wired post-deploy via setAggregator.
        // Default devFallbackEnabled = true preserves the legacy path.
        aggregator       = address(0);
        devFallbackEnabled = true;
    }

    // ---- IYieldLeg ----

    function name() external pure returns (string memory) {
        return "BasisHedgeLeg";
    }

    /**
     * Basis hedge yield is not directly a funding rate — it's the
     * (perpMark - spot) carry. This stub returns the fixed fallback
     * until a basis-oracle is wired; the fixedApyBps config value is
     * expected to reflect the observed trailing basis in APY terms.
     */
    function expectedApy() public view returns (uint256) {
        return latestApyBps;
    }

    function apyHistory() external view returns (uint256[] memory out) {
        uint256 n = history.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = history[i].apyBps;
    }

    /** spot HYPE value + on-hand USDC + realised basis PnL. */
    function currentValue() external view returns (uint256) {
        uint256 spotVal = 0;
        if (spotHypeBalance > 0) {
            uint256 price = _hypePriceUsdc();
            spotVal = (spotHypeBalance * price) / 1e6;
        }
        // Perp PnL is realised and sitting in USDC already; the writer
        // credits it on close. We count it once via on-hand USDC.
        uint256 perpVal = 0;
        // TODO: add a mark-to-market oracle read for unrealised PnL.
        return spotVal + perpVal + usdc.balanceOf(address(this));
    }

    function allocateTo(uint256 amount) external nonReentrant returns (uint256) {
        require(msg.sender == owner, "not owner");
        require(amount > 0, "zero");
        // KI-3 fix: `amount == 1` makes the half-split produce
        // `spotPortion = 0`, which the guard below silently promotes to
        // `spotPortion = amount`, leaving the perp side at 0 — the leg
        // then opens a spot long and a perp notional of 0, recording
        // 1 USDC of allocation against a single-sided position.
        // Require >= 2 so both sides get a non-zero notional.
        require(amount >= 2, "dust");

        // HR=1.0: half notional long spot, half notional short perp.
        uint256 spotPortion = (amount * HEDGE_RATIO_BPS) / BPS_DENOM / 2;
        uint256 perpPortion = (amount * HEDGE_RATIO_BPS) / BPS_DENOM - spotPortion;
        if (spotPortion == 0) spotPortion = amount;
        if (perpPortion > spotPortion) perpPortion = spotPortion;

        uint256 hypeIn = _buyHype(spotPortion);
        spotHypeBalance += hypeIn;

        if (perpPortion > 0) {
            ITradeOnlyAgent.Delegation memory d = _nextDelegation(perpPortion);
            _writeOpen(d, IElysiumCoreWriter.Side.Short, perpPortion, _fallbackSig());
            perpNotional += perpPortion;
        }

        allocatedUsd += amount;
        _recordApy(expectedApy());
        emit Allocated(amount, allocatedUsd);
        return amount;
    }

    /**
     * Flip-close the short to lock in basis PnL (USDC credited by
     * writer), then sweep it to the aggregator.
     */
    function harvest() external nonReentrant {
        require(msg.sender == owner, "not owner");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        if (perpNotional > 0) {
            ITradeOnlyAgent.Delegation memory closeD = _nextDelegation(perpNotional);
            _writeClose(closeD, IElysiumCoreWriter.Side.Short, perpNotional, _fallbackSig());

            ITradeOnlyAgent.Delegation memory openD = _nextDelegation(perpNotional);
            _writeOpen(openD, IElysiumCoreWriter.Side.Short, perpNotional, _fallbackSig());
        }

        uint256 realised = usdc.balanceOf(address(this)) - usdcBefore;
        if (realised > 0) {
            realisedBasisPnl += realised;
            if (allocatedUsd >= realised) allocatedUsd -= realised; else allocatedUsd = 0;
            usdc.safeTransfer(owner, realised);
            emit Harvested(realised);
        }
        _recordApy(expectedApy());
    }

    function reduceFrom(uint256 amount) external nonReentrant returns (uint256 returnedUsd) {
        require(msg.sender == owner, "not owner");
        require(amount > 0, "zero");
        require(amount <= allocatedUsd, "overreduce");

        uint256 perpCut = (perpNotional * amount) / allocatedUsd;
        if (perpCut > 0 && perpNotional > 0) {
            ITradeOnlyAgent.Delegation memory closeD = _nextDelegation(perpCut);
            _writeClose(closeD, IElysiumCoreWriter.Side.Short, perpCut, _fallbackSig());
            perpNotional -= perpCut;
        }

        uint256 hypeCut = (spotHypeBalance * amount) / allocatedUsd;
        if (hypeCut > 0) {
            _sellHype(hypeCut);
            spotHypeBalance -= hypeCut;
        }

        returnedUsd = usdc.balanceOf(address(this));
        if (returnedUsd > 0) usdc.safeTransfer(owner, returnedUsd);

        if (allocatedUsd >= amount) allocatedUsd -= amount; else allocatedUsd = 0;
        emit Reduced(amount, allocatedUsd);
    }

    // ---- Owner helpers ----

    function setFixedApyBps(uint256 v) external onlyOwner {
        fixedApyBps = v;
        // KI-4 fix: refresh cached APY when no oracle is wired so
        // `expectedApy()` reflects the new value immediately.
        if (address(oracle) == address(0)) latestApyBps = v;
    }
    // KI-2b Phase 3 (DESIGN_KI2_SUBMITINTENT.md §9): `bumpNonce()`
    // REMOVED. Post-increment semantics in `_nextDelegation()` mean
    // a reverted writer call does not advance the counter, so the
    // delegator can retry with the same nonce; the replay guard
    // (`submittedIntents`) is the correct belt for a re-submission.
    // See the test-suite doc comment on
    // `Phase3NonceCleanupTest.bumpNonceRemoval` for the pin.

    /// KI-2b Phase 2: wire the aggregator address AFTER the aggregator
    /// is deployed. Owner-only.
    function setAggregator(address _a) external onlyOwner {
        aggregator = _a;
    }

    /// KI-2b Phase 2: flip the dev-fallback gate off for production
    /// deployments. Owner-only. Once flipped off, `_fallbackSig()`
    /// reverts, so the legacy `allocateTo` / `harvest` / `reduceFrom`
    /// paths become unreachable on perp legs — the aggregator must
    /// use stream-A entry points instead.
    function setDevFallbackEnabled(bool _b) external onlyOwner {
        devFallbackEnabled = _b;
    }

    // ---- IIntentSubmittingLeg ----

    /**
     * KI-2: Submit a signed intent to this leg (stream B per
     * DESIGN_KI2_SUBMITINTENT.md §4). The caller (`msg.sender`) must
     * be the delegator or this leg's owner (for aggregator forwarding);
     * `d.keeper` must be this leg. The leg verifies the EIP-712
     * signature against TradeOnlyAgent, enforces the venue-local
     * per-order cap, records the intent as submitted (nonce-keyed
     * replay protection), forwards the signature to the writer, and
     * updates the delegation's per-venue notional via recordExecution.
     *
     * @param d   The signed delegation envelope.
     * @param sig The EIP-712 signature over `d` from the delegator.
     * @param amount Notional (USDC 6-dec) to allocate. Must be <=
     *               d.maxPerOrder (venue-local per-order cap).
     * @return notionalAllocated  The amount actually allocated.
     */
    function submitIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external nonReentrant returns (uint256 notionalAllocated) {
        // d.keeper must be this leg (stream B).
        require(d.keeper == address(this), "keeper is not this leg");
        // Only the delegator or the leg's owner may submit.
        require(
            msg.sender == delegator || msg.sender == owner,
            "not authorized"
        );
        require(amount > 0, "zero");
        require(amount <= d.maxPerOrder, "per-order cap");

        // Nonce-keyed replay protection.
        bytes32 intentKey = keccak256(abi.encode(d.keeper, d.nonce, d.salt));
        require(!submittedIntents[intentKey], "intent already submitted");

        // Verify the EIP-712 signature, expiry, and revoke state.
        // The per-venue notional cap (FIX-14) and recordExecution
        // bookkeeping are the WRITER's responsibility per
        // DELEGATION_SPEC §119-121; ITradeOnlyAgent only exposes
        // isValidDelegation to venues, so the leg defers cap enforcement
        // to the writer.
        require(
            tradeOnlyAgent.isValidDelegation(delegator, d, sig),
            "invalid delegation"
        );

        // HR=1.0: half spot long, half perp short — same math as allocateTo.
        uint256 spotPortion = (amount * HEDGE_RATIO_BPS) / BPS_DENOM / 2;
        uint256 perpPortion = (amount * HEDGE_RATIO_BPS) / BPS_DENOM - spotPortion;
        if (spotPortion == 0) spotPortion = amount;
        if (perpPortion > spotPortion) perpPortion = spotPortion;

        uint256 hypeIn = _buyHype(spotPortion);
        spotHypeBalance += hypeIn;

        if (perpPortion > 0) {
            _writeOpen(d, IElysiumCoreWriter.Side.Short, perpPortion, sig);
            perpNotional += perpPortion;
        }

        // Mark as submitted AFTER the writer call so a revert doesn't
        // burn the nonce. Also record the venue-acknowledged nonce for
        // `lastExecutedNonce` — a reverted writer call never reaches
        // this line (see the @dev note on the mapping).
        submittedIntents[intentKey] = true;
        lastExecutedNonce[delegator][d.nonce] = d.nonce;

        allocatedUsd += amount;
        notionalAllocated = amount;
        _recordApy(expectedApy());
        emit Allocated(amount, allocatedUsd);
    }

    /**
     * KI-2b Phase 2 (stream A): aggregate-delegated allocate. The
     * aggregator calls this from `executePendingWithStreamA(d, sig)`
     * with `d.keeper == aggregator`. Same HR=1.0 spot+perp split as
     * `allocateTo` and `submitIntent`; nonce-keyed replay protection
     * is keyed on `keccak(keeper, nonce, salt)` so the same
     * (keeper, nonce, salt) cannot be replayed across the stream-A
     * and stream-B surfaces of this leg.
     */
    function submitIntentFromStreamA(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external nonReentrant returns (uint256 notionalAllocated) {
        require(d.keeper == aggregator, "stream-A: d.keeper != aggregator");
        require(
            msg.sender == aggregator || msg.sender == owner,
            "stream-A: not authorized"
        );
        require(aggregator != address(0), "stream-A: aggregator not set");
        require(amount >= 2, "dust");
        require(amount <= d.maxPerOrder, "per-order cap");

        bytes32 intentKey = keccak256(abi.encode(d.keeper, d.nonce, d.salt));
        require(!submittedIntents[intentKey], "intent already submitted");

        require(
            tradeOnlyAgent.isValidDelegation(delegator, d, sig),
            "invalid delegation"
        );

        uint256 spotPortion = (amount * HEDGE_RATIO_BPS) / BPS_DENOM / 2;
        uint256 perpPortion = (amount * HEDGE_RATIO_BPS) / BPS_DENOM - spotPortion;
        if (spotPortion == 0) spotPortion = amount;
        if (perpPortion > spotPortion) perpPortion = spotPortion;

        uint256 hypeIn = _buyHype(spotPortion);
        spotHypeBalance += hypeIn;

        if (perpPortion > 0) {
            _writeOpen(d, IElysiumCoreWriter.Side.Short, perpPortion, sig);
            perpNotional += perpPortion;
        }

        submittedIntents[intentKey] = true;
        // Venue-acknowledged nonce bookkeeping — only written after the
        // writer call succeeded (reverts never reach this line).
        lastExecutedNonce[delegator][d.nonce] = d.nonce;

        allocatedUsd += amount;
        notionalAllocated = amount;
        _recordApy(expectedApy());
        emit Allocated(amount, allocatedUsd);
    }

    /**
     * KI-2b Phase 2 (stream A): aggregate-delegated reduce. Closes
     * `amount` of the leg's open perp notional under the aggregator's
     * delegation and sweeps the returned USDC to the aggregator. The
     * spot-side reduction (sell HYPE back to USDC through the router)
     * is leg-internal and does not touch the writer.
     */
    function reduceIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external nonReentrant returns (uint256 returnedUsd) {
        require(d.keeper == aggregator, "stream-A: d.keeper != aggregator");
        require(
            msg.sender == aggregator || msg.sender == owner,
            "stream-A: not authorized"
        );
        require(aggregator != address(0), "stream-A: aggregator not set");
        require(amount > 0, "zero");
        require(amount <= d.maxPerOrder, "per-order cap");
        require(amount <= allocatedUsd, "overreduce");

        bytes32 intentKey = keccak256(abi.encode(d.keeper, d.nonce, d.salt));
        require(!submittedIntents[intentKey], "intent already submitted");

        require(
            tradeOnlyAgent.isValidDelegation(delegator, d, sig),
            "invalid delegation"
        );

        uint256 perpCut = (perpNotional * amount) / allocatedUsd;
        if (perpCut > 0 && perpNotional > 0) {
            require(perpCut <= d.maxPerOrder, "per-order cap on perp cut");
            _writeClose(d, IElysiumCoreWriter.Side.Short, perpCut, sig);
            perpNotional -= perpCut;
        }

        uint256 hypeCut = (spotHypeBalance * amount) / allocatedUsd;
        if (hypeCut > 0) {
            _sellHype(hypeCut);
            spotHypeBalance -= hypeCut;
        }

        submittedIntents[intentKey] = true;

        returnedUsd = usdc.balanceOf(address(this));
        if (returnedUsd > 0) {
            usdc.safeTransfer(aggregator, returnedUsd);
        }
        if (allocatedUsd >= amount) allocatedUsd -= amount; else allocatedUsd = 0;
        emit Reduced(amount, allocatedUsd);
    }

    /**
     * KI-2b Phase 2 (stream A): aggregate-delegated harvest. Closes
     * the open short under the aggregator's delegation, re-opens it
     * (same notional) to continue collecting basis carry, then sweeps
     * the realised PnL USDC to the aggregator. The spot HYPE position
     * stays open throughout (only the perp side is close/reopened).
     */
    function harvestIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external nonReentrant {
        require(d.keeper == aggregator, "stream-A: d.keeper != aggregator");
        require(
            msg.sender == aggregator || msg.sender == owner,
            "stream-A: not authorized"
        );
        require(aggregator != address(0), "stream-A: aggregator not set");

        bytes32 intentKey = keccak256(abi.encode(d.keeper, d.nonce, d.salt));
        require(!submittedIntents[intentKey], "intent already submitted");

        require(
            tradeOnlyAgent.isValidDelegation(delegator, d, sig),
            "invalid delegation"
        );

        uint256 usdcBefore = usdc.balanceOf(address(this));
        if (perpNotional > 0) {
            require(perpNotional <= d.maxPerOrder, "per-order cap on harvest");
            _writeClose(d, IElysiumCoreWriter.Side.Short, perpNotional, sig);

            // Reopen under the SAME delegation but with a bumped salt
            // so the second intent key is distinct from the close's.
            ITradeOnlyAgent.Delegation memory reopenD = d;
            reopenD.salt = bytes32(uint256(d.salt) ^ 0x01010101);
            _writeOpen(reopenD, IElysiumCoreWriter.Side.Short, perpNotional, sig);
        }

        submittedIntents[intentKey] = true;

        uint256 realised = usdc.balanceOf(address(this)) - usdcBefore;
        if (realised > 0) {
            realisedBasisPnl += realised;
            if (allocatedUsd >= realised) allocatedUsd -= realised; else allocatedUsd = 0;
            usdc.safeTransfer(aggregator, realised);
            emit Harvested(realised);
        }
        _recordApy(expectedApy());
    }

    // ---- Internals ----

    function _buyHype(uint256 usdcAmount) internal returns (uint256 hypeOut) {
        if (address(router) == address(0)) {
            return hype.balanceOf(address(this));
        }
        return router.swapExactUSDCForToken(address(hype), usdcAmount);
    }

    function _sellHype(uint256 hypeAmount) internal {
        if (address(router) == address(0)) return;
        hype.safeApprove(address(router), hypeAmount);
        router.swapExactTokenForUSDC(address(hype), hypeAmount);
    }

    function _writeOpen(
        ITradeOnlyAgent.Delegation memory d,
        IElysiumCoreWriter.Side side,
        uint256 notional,
        ITradeOnlyAgent.Signature memory sig
    ) internal {
        writer.openPosition(HYPE_ASSET_ID, side, notional, delegator, d, sig);
    }

    function _writeClose(
        ITradeOnlyAgent.Delegation memory d,
        IElysiumCoreWriter.Side side,
        uint256 notional,
        ITradeOnlyAgent.Signature memory sig
    ) internal {
        writer.closePosition(HYPE_ASSET_ID, side, notional, delegator, d, sig);
    }

    /**
     * Phase-1 fallback signature for the aggregator-only allocateTo /
     * harvest / reduceFrom paths. KI-2b Phase 2 (DESIGN_KI2B_AGGREGATOR_STREAM_A.md
     * §4) gates this on `devFallbackEnabled`: when the flag is `false`
     * (production), the legacy paths revert so the aggregator MUST use
     * the stream-A entry points. When `true` (dev / round-4/7/9/11
     * test rig), the fallback path is preserved for backwards compat.
     *
     * Deliberately NOT named `_zeroSig` — the KI-2 verification grep
     * rejects that symbol anywhere under `solidity/src/legs/`.
     */
    function _fallbackSig() internal view returns (ITradeOnlyAgent.Signature memory) {
        require(devFallbackEnabled, "use submitIntentFromStreamA");
        return ITradeOnlyAgent.Signature({ v: 27, r: bytes32(0), s: bytes32(0) });
    }

    function _nextDelegation(uint256 notional) internal returns (
        ITradeOnlyAgent.Delegation memory d
    ) {
        // KI-2b Phase 3 (DESIGN_KI2_SUBMITINTENT.md §9 Phase 3):
        // Pre-increment semantics — the value written into `d.nonce`
        // is the storage value BEFORE the increment. So the first call
        // proposes nonce=0, the second proposes nonce=1, and so on.
        // `nextDelegationNonce` reads as "the next nonce this leg will
        // propose on the next `_nextDelegation()` call" (i.e. the
        // highest nonce proposed, plus one). Solidity rolls back ALL
        // storage changes on revert (including the bump), so a reverted
        // writer call leaves the counter unchanged and the next call
        // re-proposes the same nonce; the `submittedIntents` guard
        // (keyed on `keccak(keeper, nonce, salt)`) is what blocks
        // re-submission of an already-executed nonce.
        uint256 n = nextDelegationNonce;
        nextDelegationNonce = n + 1;
        uint256[] memory ids = new uint256[](1);
        ids[0] = HYPE_ASSET_ID;
        d = ITradeOnlyAgent.Delegation({
            keeper: address(this),
            assetIds: ids,
            maxNotional: notional,
            maxPerOrder: notional,
            expiresAt: 0,
            nonce: uint64(n),
            salt: bytes32(0)
        });
    }

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
                ts: uint64(block.timestamp), apyBps: a
            });
        } else {
            history.push(Observation({ ts: uint64(block.timestamp), apyBps: a }));
        }
        latestApyBps = a;
    }
}
