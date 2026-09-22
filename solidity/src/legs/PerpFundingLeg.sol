// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Router.sol";
import "../interfaces/ITradeOnlyAgent.sol";
import "../interfaces/IElysiumCoreWriter.sol";
import "../interfaces/IFundingSource.sol";
import "../interfaces/IPriceOracle.sol";

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
contract PerpFundingLeg is IYieldLeg {
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
            _writeOpen(d, IElysiumCoreWriter.Side.Short, perpPortion);
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
            _writeClose(closeD, IElysiumCoreWriter.Side.Short, perpNotional);

            ITradeOnlyAgent.Delegation memory openD = _nextDelegation(perpNotional);
            _writeOpen(openD, IElysiumCoreWriter.Side.Short, perpNotional);
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
            _writeClose(closeD, IElysiumCoreWriter.Side.Short, perpCut);
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
        uint256 notional
    ) internal {
        writer.openPosition(
            HYPE_ASSET_ID, side, notional, delegator, d, _zeroSig()
        );
    }

    function _writeClose(
        ITradeOnlyAgent.Delegation memory d,
        IElysiumCoreWriter.Side side,
        uint256 notional
    ) internal {
        writer.closePosition(
            HYPE_ASSET_ID, side, notional, delegator, d, _zeroSig()
        );
    }

    /**
     * Build a fresh Delegation envelope. keeper = this leg (the
     * delegator signed a delegation whose keeper is the leg address).
     *
     * @dev This stub returns a zero-signature and a fresh nonce; the
     *      real flow will require the delegator to sign the exact
     *      envelope and pass `sig` in via a dedicated intent method.
     *      TODO: add a `submitIntent(Delegation, Signature, uint256)`
     *           path for production use.
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

    function _zeroSig() internal pure returns (ITradeOnlyAgent.Signature memory) {
        return ITradeOnlyAgent.Signature({ v: 27, r: bytes32(0), s: bytes32(0) });
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
