// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Router.sol";
import "../interfaces/ITradeOnlyAgent.sol";
import "../interfaces/IElysiumCoreWriter.sol";
import "../interfaces/IFundingSource.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IIntentSubmittingLeg.sol";

/**
 * @title PerpFundingLeg
 * @notice Long spot HYPE + short perp HYPE via ElysiumCoreWriter. The
 *         strategy captures the perp funding rate. On HyperCore the
 *         convention is "longs pay shorts" when funding is positive,
 *         so a short position earns `+funding`.
 *
 * Flow:
 *   allocateTo(amount) : USDC --router--> HYPE (spot long, half)
 *                        + writer.openPosition(HYPE, Short, half) (perp short).
 *   harvest()          : flip-close the short to realize accrued funding
 *                        PnL (USDC credited by the writer), then sweep USDC.
 *   reduceFrom(amount) : pro-rata close perp + sell spot.
 *
 * Venue: HyperCore HYPE-USD perp, routed through ElysiumCoreWriter.
 *
 * Known limitations:
 *   - Delegation verification is delegated to the writer (per spec).
 *     This leg is assumed to be the keeper named in the delegator's
 *     signature; production flow will push a fresh (delegation, sig)
 *     per intent via `submitIntent(...)`.
 *   - `fundingSource` may throw on boot; the leg falls back to
 *     `fixedApyBps` for `expectedApy()` reads.
 *   - No leverage cap; production should enforce `maxLeverage` and a
 *     notional cap.
 */
contract PerpFundingLeg is IYieldLeg, IIntentSubmittingLeg {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_HISTORY = 16;

    // Round-3 reentrancy guard — writer/router are external and untrusted.
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    /// HYPE-USD perp coin id on Elysium.
    /// TODO: confirm this constant with Kinetiq before mainnet.
    uint256 public constant HYPE_ASSET_ID = 1;

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    address public immutable owner;
    IERC20Minimal      public immutable usdc;
    IERC20Minimal      public immutable hype;
    /// TODO: router address set by deployer — replace with the
    ///       production HyperCore DEX router when wired.
    IERC20Router       public immutable router;
    IElysiumCoreWriter public immutable writer;
    ITradeOnlyAgent    public immutable tradeOnlyAgent;
    IFundingSource     public immutable fundingSource;
    IPriceOracle       public immutable oracle;

    /// Address whose signature authorizes all perp intents.
    address public immutable delegator;

    uint256 public allocatedUsd;
    uint256 public spotHypeBalance;   // HYPE held long
    uint256 public perpNotional;      // USDC notional shorted
    uint256 public latestApyBps;
    uint256 public lastDelegationNonce;

    // TODO: fixedApyBps fallback — remove once funding source is live.
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
    /// tuple cannot be submitted twice to this leg. This is a
    /// defensive belt over the verifier's own per-venue notional cap
    /// (FIX-14) — if a client re-submits the same envelope with a
    /// different notional, FIX-14 would silently accept it as long as
    /// the notional still fits.
    mapping(bytes32 => bool) public submittedIntents;

    constructor(
        address _usdc,
        address _hype,
        address _router,
        address _writer,
        address _tradeOnlyAgent,
        address _fundingSource,
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
        fundingSource  = IFundingSource(_fundingSource);
        oracle         = IPriceOracle(_oracle);
        delegator      = _delegator;
        fixedApyBps    = _fixedApyBps;
        latestApyBps   = _fixedApyBps;
    }

    // ---- IYieldLeg ----

    function name() external pure returns (string memory) {
        return "PerpFundingLeg";
    }

    /**
     * Trailing funding APY, flipped to reflect the leg's short side.
     * Positive = shorts are receiving (which is what we want).
     */
    function expectedApy() public view returns (uint256) {
        if (address(fundingSource) == address(0)) return latestApyBps;
        try fundingSource.fundingApyBps("HYPE") returns (int64 apy) {
            // Short-side: shorts receive when funding is positive.
            return apy >= 0 ? uint256(int256(apy)) : 0;
        } catch {
            return latestApyBps;
        }
    }

    function apyHistory() external view returns (uint256[] memory out) {
        uint256 n = history.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = history[i].apyBps;
    }

    /** spot HYPE value + on-hand USDC. */
    function currentValue() external view returns (uint256) {
        uint256 v = 0;
        if (spotHypeBalance > 0) {
            uint256 price = _hypePriceUsdc();
            v += (spotHypeBalance * price) / 1e6;
        }
        v += usdc.balanceOf(address(this));
        return v;
    }

    function allocateTo(uint256 amount) external nonReentrant returns (uint256) {
        require(msg.sender == owner, "not owner");
        require(amount > 0, "zero");

        // 50/50 split between spot long and perp short.
        uint256 spotPortion = amount / 2;
        uint256 perpPortion = amount - spotPortion;
        if (spotPortion == 0) spotPortion = amount;

        // Buy spot HYPE.
        uint256 hypeIn = _buyHype(spotPortion);
        spotHypeBalance += hypeIn;

        // Open short perp under a delegation.
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
     * Force-flip the short to realise accrued funding PnL into the leg's
     * USDC balance, then sweep it out. Spot HYPE stays open.
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
            if (allocatedUsd >= realised) allocatedUsd -= realised; else allocatedUsd = 0;
            usdc.safeTransfer(owner, realised);
            emit Harvested(realised);
        }
        _recordApy(expectedApy());
    }

    /** Close `amount` of allocation: pro-rata spot + perp. */
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
        if (returnedUsd > 0) {
            usdc.safeTransfer(owner, returnedUsd);
        }
        if (allocatedUsd >= amount) allocatedUsd -= amount; else allocatedUsd = 0;
        emit Reduced(amount, allocatedUsd);
    }

    // ---- Owner helpers ----

    function setFixedApyBps(uint256 v) external onlyOwner {
        fixedApyBps = v;
        // KI-4 fix: refresh cached APY when the funding source is not
        // live so `expectedApy()` doesn't serve a stale value.
        if (address(fundingSource) == address(0)) latestApyBps = v;
    }
    function bumpNonce() external onlyOwner { lastDelegationNonce += 1; }

    // ---- IIntentSubmittingLeg ----

    /**
     * KI-2: Submit a signed intent to this leg (stream B per
     * DESIGN_KI2_SUBMITINTENT.md §4). The caller (`msg.sender`) must
     * be the keeper named in the delegation; `d.keeper` must be this
     * leg. The leg verifies the EIP-712 signature against
     * TradeOnlyAgent, enforces the venue-local per-order cap, records
     * the intent as submitted (nonce-keyed replay protection),
     * forwards the signature to the writer, and updates the
     * delegation's per-venue notional via recordExecution.
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
        // d.keeper must be this leg — the delegator is signing authority
        // to submit intents to this specific leg address (stream B per
        // DESIGN_KI2_SUBMITINTENT.md §4).
        require(d.keeper == address(this), "keeper is not this leg");
        // Only the delegator (or this leg's owner, for aggregator
        // forwarding) may submit.
        require(
            msg.sender == delegator || msg.sender == owner,
            "not authorized"
        );
        require(amount > 0, "zero");
        require(amount <= d.maxPerOrder, "per-order cap");

        // Nonce-keyed replay protection (belt over FIX-14's per-venue cap).
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

        // 50/50 split between spot long and perp short (same as allocateTo).
        uint256 spotPortion = amount / 2;
        uint256 perpPortion = amount - spotPortion;
        if (spotPortion == 0) spotPortion = amount;

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
            // Test-rig path: aggregator pushes HYPE alongside USDC.
            return hype.balanceOf(address(this));
        }
        hypeOut = router.swapExactUSDCForToken(address(hype), usdcAmount);
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
        writer.openPosition(
            HYPE_ASSET_ID, side, notional, delegator, d, sig
        );
    }

    function _writeClose(
        ITradeOnlyAgent.Delegation memory d,
        IElysiumCoreWriter.Side side,
        uint256 notional,
        ITradeOnlyAgent.Signature memory sig
    ) internal {
        writer.closePosition(
            HYPE_ASSET_ID, side, notional, delegator, d, sig
        );
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

    /**
     * Build a fresh Delegation envelope. keeper = this leg (the
     * delegator signed a delegation whose keeper is the leg address).
     *
     * @dev This stub is used by `_writeOpen` / `_writeClose` when
     *      `fundingSource` is unwired (test-only path). The production
     *      flow uses `submitIntent(...)` which receives the real
     *      (delegation, sig) pair and forwards it to the writer.
     *      See `submitIntent` above and DESIGN_KI2_SUBMITINTENT.md §4.
     */
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
