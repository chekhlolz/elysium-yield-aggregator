// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Router.sol";
import "../interfaces/IXHYPELeg.sol";
import "../interfaces/IPriceOracle.sol";

/**
 * @title LiminalXHYPELeg
 * @notice Wraps Liminal's xHYPE ERC-4626 vault as the 5th leg of
 *         YieldAggregator. The vault offers a live ~14.50% APY on
 *         HYPE, roughly 8x the kHYPE 1.83% baseline. This leg is a
 *         strictly-better HYPE vehicle: the RegimeDetector migrates
 *         weight from kHYPE into xHYPE first, then into the rest of
 *         the pool (see `weightsForRegime` for the exact allocation).
 *
 * Flow:
 *   allocateTo(USD):  USDC --router--> HYPE --vault.deposit--> xHYPE shares.
 *   harvest():        sweeps any residual USDC back to owner; vault
 *                     accrual is captured in the share exchange rate.
 *   reduceFrom(USD):  vault.withdraw(HYPE) --> USDC (returned to owner).
 *
 * Security:
 *   - CCE reentrancy guard on every mutating entry point. The vault
 *     is a third-party ERC-4626 and could conceivably call back via
 *     a malicious receiver; we treat it as untrusted.
 *   - Slippage bound against the oracle price AFTER the swap, using
 *     the same pattern as KHYPELeg (round-8 hardening).
 *   - `isLiquidatable()` is enforced on allocateTo so a paused vault
 *     cannot strand aggregator cash.
 *   - Max USD cap (`maxAllocationUsd`, 6-dec USDC units) enforces the
 *     aggregator-level weight cap even if requestAllocation bypasses
 *     it — a defence-in-depth against a compromised keeper routing
 *     the entire vault into a single venue.
 *   - The leg does NOT decrement `allocatedUsd` on `harvest()` — the
 *     vault's principal is tracked as an outstanding-share position,
 *     and the mark-to-market value (via `currentValue()`) already
 *     reflects accrued yield. Decrementing would drift
 *     `allocatedUsd` below what the vault actually holds.
 *
 * EIP-4626 shape: the vault is treated as a standard ERC-4626
 * (deposit/mint/withdraw/redeem, convertToShares/convertToAssets,
 * preview*). We do not re-define any of that shape here; we call
 * the vault directly via the local IERC4626Minimal view.
 */
contract LiminalXHYPELeg is IYieldLeg, IXHYPELeg {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_HISTORY = 16;

    // Round-3 reentrancy guard — router and vault are external and
    // untrusted. CCE pattern identical to KHYPELeg.
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    address public immutable owner;
    IERC20Minimal public immutable usdc;
    IERC20Minimal public immutable hype;
    IERC20Router public immutable router;
    IERC4626Minimal public immutable vault;
    IPriceOracle public immutable oracle;

    uint256 public allocatedUsd;
    /// Leg's share count in the xHYPE vault. 18-dec by the 4626
    /// convention; the live `convertToAssets(1e18)` gives the
    /// share→HYPE exchange rate at any moment.
    uint256 public shareBalance;
    uint256 public latestApyBps;

    // Fallback APY value used when the vault does not expose `apyBps()`.
    // Governance may update this to keep `expectedApy()` meaningful when
    // the vault's own APY feed is unavailable.
    uint256 public fixedApyBps;

    // Slippage ceiling for the USDC→HYPE swap, bounded AFTER the swap
    // returns. 0 disables the guard (tests with exact fills); 100
    // (1%) is the recommended production default.
    uint256 public slippageBps;

    /// Owner-set USD ceiling for this leg (6-dec USDC units).
    /// 0 = unlimited (governance opt-out). Enforced inside allocateTo
    /// as a defence-in-depth against a keeper routing the entire vault
    /// into a single venue.
    uint256 public maxAllocationUsd;

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
        address _xhypeVault,
        address _oracle,
        uint256 _fixedApyBps,
        uint256 _slippageBps,
        uint256 _maxAllocationUsd
    ) {
        require(_xhypeVault != address(0), "zero vault");
        require(_slippageBps <= BPS_DENOM, "slippageBps > 100%");
        owner = msg.sender;
        usdc = IERC20Minimal(_usdc);
        hype = IERC20Minimal(_hype);
        router = IERC20Router(_router);
        vault = IERC4626Minimal(_xhypeVault);
        oracle = IPriceOracle(_oracle);
        fixedApyBps = _fixedApyBps;
        latestApyBps = _fixedApyBps;
        slippageBps = _slippageBps;
        maxAllocationUsd = _maxAllocationUsd;
    }

    // ---- IYieldLeg ----

    function name() external pure returns (string memory) {
        return "LiminalXHYPELeg";
    }

    /**
     * expectedApy() is the vault's advertised APY when readable;
     * falls back to the cached `latestApyBps` otherwise. Because a
     * hostile vault could return 0 or an absurd value, callers that
     * need a lower bound should also check `isLiquidatable()`.
     */
    function expectedApy() public view returns (uint256) {
        if (address(oracle) == address(0)) {
            // No oracle: use the vault's own APY if it implements
            // IXHYPELeg, otherwise the cached fallback.
            try this.apyBps() returns (uint256 a) {
                if (a > 0) return a;
            } catch {}
            return latestApyBps;
        }
        try oracle.getApy("xHYPE") returns (uint256 a) {
            return a;
        } catch {
            return latestApyBps;
        }
    }

    function apyHistory() external view returns (uint256[] memory out) {
        uint256 n = history.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = history[i].apyBps;
        }
    }

    /**
     * Mark-to-market value of the leg's position.
     *
     * xHYPE shares accrue yield through the share exchange rate
     * (shareBalance * convertToAssets(1e18) = HYPE principal today).
     * We convert to USDC using the live oracle price, then add any
     * residual USDC sitting in this leg.
     *
     * Under the vault's convention (18-dec shares, 18-dec rate):
     *   assets_18dec = shareBalance * convertToAssets(1e18) / 1e18
     *   usdc_6dec    = assets_18dec * price / 1e18
     * Combined:
     *   usdc_6dec    = (shareBalance * rate * price) / 1e36
     */
    function currentValue() external view returns (uint256) {
        uint256 v = 0;
        if (shareBalance > 0) {
            uint256 price = _hypePriceUsdc();
            if (price > 0) {
                uint256 rate = _safeConvertToAssets(1e18);
                // shareBalance_18 * rate_18 * price_6 / 1e36 = USDC_6
                v = (shareBalance * rate * price) / 1_000_000_000_000_000_000_000_000_000_000_000_000;
            }
        }
        v += usdc.balanceOf(address(this));
        return v;
    }

    function allocateTo(uint256 usdAmount) external nonReentrant returns (uint256) {
        require(msg.sender == owner, "not owner");
        require(usdAmount > 0, "zero");
        require(_isLiquidatableSafe(), "vault not liquidatable");
        require(maxAllocationUsd == 0 || allocatedUsd + usdAmount <= maxAllocationUsd, "max allocation exceeded");

        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");

        uint256 hypeIn = router.swapExactUSDCForToken(address(hype), usdAmount);
        require(hypeIn > 0, "router returned 0");

        // Round-8 slippage hardening (same pattern as KHYPELeg).
        if (slippageBps > 0) {
            uint256 hypeMin = (usdAmount * 1_000_000_000_000_000_000 * (BPS_DENOM - slippageBps)) / (price * BPS_DENOM);
            require(hypeIn >= hypeMin, "slippage exceeded");
        }

        // 4626: approve HYPE to the vault, then deposit.
        hype.safeApprove(address(vault), hypeIn);
        uint256 newShares = vault.deposit(hypeIn, address(this));
        require(newShares > 0, "vault mint 0");

        shareBalance += newShares;
        allocatedUsd += usdAmount;

        _recordApy(expectedApy());
        emit Allocated(usdAmount, allocatedUsd);
        return usdAmount;
    }

    /**
     * Harvest any residual USDC sitting in this leg. Yield accrued
     * via the vault is captured in the share exchange rate and flows
     * through currentValue() — no separate claim() is needed.
     *
     * allocatedUsd is NOT decremented on harvest (round-8 pattern):
     * the vault position is outstanding-shares, not realised USDC.
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
        require(usdAmount > 0, "bad amount");
        require(shareBalance > 0, "bad amount");
        uint256 price = _hypePriceUsdc();
        require(price > 0, "no oracle price");

        // Convert requested USDC reduction to 18-dec HYPE.
        uint256 hypeAmount = (usdAmount * 1_000_000_000_000_000_000) / price;
        require(hypeAmount > 0, "zero hype amount");

        // Convert HYPE to shares via the vault's live share rate.
        uint256 rate = _safeConvertToAssets(1e18);
        require(rate > 0, "vault rate is 0");
        uint256 sharesToBurn = (hypeAmount * 1e18) / rate;
        require(sharesToBurn > 0, "zero share amount");
        require(shareBalance >= sharesToBurn, "bad amount");

        shareBalance -= sharesToBurn;

        uint256 hypeOut = 0;
        // Snapshot the HYPE balance BEFORE calling vault.withdraw so
        // we can compute the credit delta even if the vault does not
        // return the underlying amount.
        uint256 balBefore = hype.balanceOf(address(this));
        try vault.withdraw(hypeAmount, address(this), address(this)) returns (uint256 sharesBurned) {
            uint256 balAfter = hype.balanceOf(address(this));
            hypeOut = balAfter >= balBefore ? balAfter - balBefore : 0;
            // `sharesBurned` is what the vault actually burned. Some
            // 4626 vaults may under-burn on rounding (rounding loss
            // paid by the redeemer); if so, claw back the delta so our
            // ledger does not drift from the vault's book.
            if (sharesToBurn > sharesBurned) {
                shareBalance += (sharesToBurn - sharesBurned);
            }
        } catch {
            // Vault refused the withdraw. Restore the ledger so we
            // don't leave ourselves over-counted, then bail with 0
            // return.
            shareBalance += sharesToBurn;
        }

        if (hypeOut > 0) {
            hype.safeApprove(address(router), hypeOut);
            uint256 u = router.swapExactTokenForUSDC(address(hype), hypeOut);
            usdc.safeTransfer(owner, u);
            returnedUsd = u;
        }

        allocatedUsd = usdAmount <= allocatedUsd ? allocatedUsd - usdAmount : 0;

        emit Reduced(usdAmount, allocatedUsd);
    }

    // ---- IXHYPELeg ----

    function apyBps() external view returns (uint256) {
        // The wrapped vault may implement IXHYPELeg itself; if so,
        // delegate. Otherwise fall back to the cached latest.
        if (address(oracle) != address(0)) {
            try oracle.getApy("xHYPE") returns (uint256 a) {
                if (a > 0) return a;
            } catch {}
        }
        try IXHYPELeg(address(vault)).apyBps() returns (uint256 a) {
            if (a > 0) return a;
        } catch {}
        return latestApyBps;
    }

    function isLiquidatable() external view returns (bool) {
        return _isLiquidatableSafe();
    }

    // ---- Owner helpers ----

    /**
     * Governance: change the fixed-APY fallback.
     *  Only refreshes `latestApyBps` when the oracle is unwired,
     *  matching the KHYPELeg pattern.
     */
    function setFixedApyBps(uint256 v) external onlyOwner {
        fixedApyBps = v;
        if (address(oracle) == address(0)) latestApyBps = v;
    }

    /**
     * Governance: change the slippage ceiling in basis points.
     *  0 disables the guard entirely; 100 (1%) is production-default.
     */
    function setSlippageBps(uint256 v) external onlyOwner {
        require(v <= BPS_DENOM, "slippageBps > 100%");
        slippageBps = v;
    }

    /**
     * Governance: change the max-USD cap. 0 = unlimited.
     */
    function setMaxAllocationUsd(uint256 v) external onlyOwner {
        maxAllocationUsd = v;
    }

    // ---- Internals ----

    function _hypePriceUsdc() internal view returns (uint256) {
        if (address(oracle) == address(0)) return 0;
        try oracle.priceOf("HYPE") returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }

    function _safeConvertToAssets(uint256 shares) internal view returns (uint256) {
        try vault.convertToAssets(shares) returns (uint256 a) {
            return a;
        } catch {
            return 0;
        }
    }

    function _isLiquidatableSafe() internal view returns (bool) {
        try IXHYPELeg(address(vault)).isLiquidatable() returns (bool ok) {
            return ok;
        } catch {
            // If the vault does not implement isLiquidatable() at all
            // (uninformative call), we cannot tell — assume liquid.
            // The vault will reject the actual deposit call anyway if
            // it is paused, so the leg fails closed at the vault
            // boundary rather than here.
            return true;
        }
    }

    function _recordApy(uint256 a) internal {
        if (history.length >= MAX_HISTORY) {
            for (uint256 i = 0; i < MAX_HISTORY - 1; i++) {
                history[i] = history[i + 1];
            }
            history[MAX_HISTORY - 1] = Observation({ts: uint64(block.timestamp), apyBps: a});
        } else {
            history.push(Observation({ts: uint64(block.timestamp), apyBps: a}));
        }
        latestApyBps = a;
    }
}
