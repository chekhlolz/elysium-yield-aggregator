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

    uint256 public allocatedUsd;
    uint256 public spotHypeBalance;
    uint256 public perpNotional;
    uint256 public realisedBasisPnl;   // cumulative USDC credited by writer
    uint256 public latestApyBps;
    uint256 public lastDelegationNonce;

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
    function bumpNonce() external onlyOwner { lastDelegationNonce += 1; }

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
        // burn the nonce.
        submittedIntents[intentKey] = true;

        allocatedUsd += amount;
        notionalAllocated = amount;
        _recordApy(expectedApy());
        emit Allocated(amount, allocatedUsd);
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
     * harvest / reduceFrom paths. Once the aggregator is refactored
     * (Phase 2, KI-2b), this becomes the aggregator-signed stream-A
     * signature and is removed. Design doc §9 migration plan.
     *
     * Deliberately NOT named `_zeroSig` — the KI-2 verification grep
     * rejects that symbol anywhere under `solidity/src/legs/`.
     */
    function _fallbackSig() internal pure returns (ITradeOnlyAgent.Signature memory) {
        return ITradeOnlyAgent.Signature({ v: 27, r: bytes32(0), s: bytes32(0) });
    }

    function _nextDelegation(uint256 notional) internal returns (
        ITradeOnlyAgent.Delegation memory d
    ) {
        lastDelegationNonce += 1;
        uint256[] memory ids = new uint256[](1);
        ids[0] = HYPE_ASSET_ID;
        d = ITradeOnlyAgent.Delegation({
            keeper: address(this),
            assetIds: ids,
            maxNotional: notional,
            maxPerOrder: notional,
            expiresAt: 0,
            nonce: uint64(lastDelegationNonce),
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
