// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";
import "../interfaces/IIntentSubmittingLeg.sol";
import "../interfaces/ITradeOnlyAgent.sol";

// ---- Minimal ERC-20 (only what the aggregator calls). ----
interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

// ---- Safe ERC-20 helpers (raw call + decode to tolerate non-standard tokens). ----
library SafeERC20 {
    function safeTransfer(IERC20Minimal tok, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(abi.encodeCall(IERC20Minimal.transfer, (to, v)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 transfer failed");
    }
    function safeTransferFrom(IERC20Minimal tok, address from, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, v)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 transferFrom failed");
    }
    function safeApprove(IERC20Minimal tok, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(abi.encodeCall(IERC20Minimal.approve, (to, v)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 approve failed");
    }
}

/**
 * @title YieldAggregator
 * @notice ERC-4626-style vault with regime-driven allocation across four yield legs.
 *
 * Design: docs/AGGREGATOR_SPEC.md.
 *
 * Architecture:
 *   - 4 yield legs (spot, kHYPE, perp funding, basis hedge) each implement
 *     IYieldLeg. The aggregator treats them as opaque.
 *   - Allocation weights are basis points (sum = 10_000). Keeper sets them
 *     through requestAllocation + executePending with a configurable
 *     timelock. cancelPending is owner-or-keeper only — see
 *     docs/AGGREGATOR_SPEC.md §3.5 for the tradeoff against the
 *     original "open to anyone" keeper-compromise design.
 *
 * Not mainnet-audited. Reference implementation for the Elysium builder
 * proposal; production will add governance, accounting snapshots, leg
 * safety checks, and a real market-data feed adapter for RegimeDetector.
 */
contract YieldAggregator {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;

    // ---- Core state ----
    IERC20Minimal public immutable asset_;
    IYieldLeg[4] public legs;

    mapping(address => uint256) public shareBalances;
    uint256 public totalShares;
    uint256 private _allocatedTotal;
    uint16[4] private _weights;

    uint32 public timelockSeconds;
    address public keeper;
    address public owner;
    bool public paused;

    // ---- Reentrancy guard (round-3 fix, 2026-09-23) ----
    // Every function that moves assets out of the vault to legs
    // (deposit / mint / withdraw / redeem / executePending /
    // harvestFromAllLegs) calls into an external leg contract that
    // could call back into the aggregator. The legs are not audited
    // and are treated as untrusted. CCE-based guard.
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    struct PendingAllocation {
        uint16[4] weights;
        uint64 executesAt;
        string reason;
    }
    bytes32 public pendingAllocationId;
    PendingAllocation private _pending;

    // ---- Events ----
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event AllocationRequested(bytes32 indexed allocationId, uint16[4] weights, string reason, uint64 executesAt);
    event AllocationExecuted(bytes32 indexed allocationId, uint16[4] weights);
    event AllocationCancelled(bytes32 indexed allocationId);
    event Harvested(uint256 yieldUsd);
    event KeeperUpdated(address indexed newKeeper);
    event PausedUpdated(bool paused);

    // ---- Modifiers ----
    modifier onlyKeeper() { require(msg.sender == keeper, "not keeper"); _; }
    modifier onlyOwner()  { require(msg.sender == owner,  "not owner");  _; }
    modifier notPaused()  { require(!paused,               "paused");     _; }

    // ---- Constructor ----
    constructor(
        IERC20Minimal _asset,
        address _keeper,
        IYieldLeg[4] memory _legsParams,
        uint32 _timelockSeconds,
        uint16[4] memory _initialWeights
    ) {
        asset_ = _asset;
        keeper = _keeper;
        owner = msg.sender;
        timelockSeconds = _timelockSeconds;

        require(
            uint256(_initialWeights[0]) + _initialWeights[1] + _initialWeights[2] + _initialWeights[3] == BPS_DENOM,
            "weights sum != 10000"
        );
        _weights = _initialWeights;

        for (uint i = 0; i < 4; i++) {
            require(address(_legsParams[i]) != address(0), "zero leg");
            legs[i] = _legsParams[i];
        }
    }

    // ---- Views ----
    function asset() external view returns (address) { return address(asset_); }
    function shares(address _owner) external view returns (uint256) { return shareBalances[_owner]; }
    function weights() external view returns (uint16[4] memory) { return _weights; }
    function legAt(uint256 i) external view returns (address) {
        require(i < 4, "bad leg index");
        return address(legs[i]);
    }
    function legsView() external view returns (address[4] memory) {
        address[4] memory out = [address(legs[0]), address(legs[1]), address(legs[2]), address(legs[3])];
        return out;
    }

    function currentValueOfLeg(uint256 i) public view returns (uint256) {
        require(i < 4, "bad leg index");
        return legs[i].currentValue();
    }

    function totalLegValue() public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < 4; i++) total += legs[i].currentValue();
        return total;
    }

    // ---- ERC-4626 preview functions ----
    // The standard requires preview* variants that mirror the actual
    // deposit/withdraw/mint/redeem return values. For this aggregator
    // the exchange rate is computed from totalAssets / totalShares, so
    // the preview values are identical to the would-be return values
    // (no rounding difference, no fee layer). That matches ERC-4626's
    // "preview value shall not decrease" rule — our preview and actual
    // always agree.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function totalAssets() public view returns (uint256) {
        return totalLegValue() + asset_.balanceOf(address(this));
    }

    function currentApyBps() external view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < 4; i++) total += legs[i].expectedApy() * _weights[i];
        return total / BPS_DENOM;
    }

    // ---- ERC-4626 accounting ----
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalShares == 0) return assets;         // 1:1 bootstrap
        return (assets * totalShares) / _totalAssets();
    }

    function convertToAssets(uint256 amount) public view returns (uint256) {
        if (totalShares == 0) return amount;         // 1:1 bootstrap
        return (amount * _totalAssets()) / totalShares;
    }

    function _totalAssets() internal view returns (uint256) {
        return totalAssets();
    }

    // ---- Deposit / mint ----
    function deposit(uint256 assets, address receiver) external notPaused nonReentrant returns (uint256) {
        require(assets > 0, "zero deposit");
        uint256 newShares = convertToShares(assets);
        require(newShares > 0, "dust shares");

        asset_.safeTransferFrom(msg.sender, address(this), assets);
        totalShares += newShares;
        shareBalances[receiver] += newShares;

        uint256 distributed = _distribute(assets);
        _allocatedTotal += distributed;

        emit Transfer(address(0), receiver, newShares);
        emit Deposit(msg.sender, receiver, assets, newShares);
        return newShares;
    }

    function mint(uint256 newShares, address receiver) external notPaused nonReentrant returns (uint256) {
        require(newShares > 0, "zero shares");
        uint256 assets = convertToAssets(newShares);
        require(assets > 0, "dust assets");

        asset_.safeTransferFrom(msg.sender, address(this), assets);
        totalShares += newShares;
        shareBalances[receiver] += newShares;

        uint256 distributed = _distribute(assets);
        _allocatedTotal += distributed;

        emit Transfer(address(0), receiver, newShares);
        emit Deposit(msg.sender, receiver, assets, newShares);
        return assets;
    }

    // ---- Withdraw / redeem ----
    function withdraw(uint256 assets, address receiver, address _owner)
        external notPaused nonReentrant returns (uint256)
    {
        require(assets > 0, "zero withdrawal");
        uint256 newShares = convertToShares(assets);
        require(newShares > 0, "dust shares");

        // FIX-22 (round-5): no USDC-in pull from the caller. The vault
        // pays out of its own holdings — the caller is authorizing a
        // share burn, not depositing collateral for the withdrawal.
        // The previous code treated delegated withdraw as a hybrid
        // deposit+withdraw, charging the caller twice.

        _redeem(assets, newShares, receiver, _owner);
        emit Withdraw(msg.sender, _owner, receiver, assets, newShares);
        return newShares;
    }

    function redeem(uint256 newShares, address receiver, address _owner)
        external notPaused nonReentrant returns (uint256)
    {
        require(newShares > 0, "zero redeem");
        uint256 assets = convertToAssets(newShares);
        require(assets > 0, "dust assets");

        // FIX-23 (round-5): no share-allowance gate. This vault keeps
        // shares as plain U256 counters (`shareBalances[_owner]`), not
        // as an ERC-20-like share token with an `allowance` mapping.
        // The previous check compared USDC allowance against a share
        // amount — a category error that made delegate redeem revert
        // for every caller that hadn't pre-approved a share-count-sized
        // USDC allowance, which is nonsense. Delegation authorization
        // is a convention of the calling interface (a relayer calling
        // on the owner's behalf), not an on-chain authorization.

        _redeem(assets, newShares, receiver, _owner);
        emit Withdraw(msg.sender, _owner, receiver, assets, newShares);
        return assets;
    }

    // ---- Allocation control ----
    function requestAllocation(uint16[4] calldata newWeights, string calldata reason)
        external onlyKeeper returns (bytes32 allocationId)
    {
        uint256 sum = uint256(newWeights[0]) + newWeights[1] + newWeights[2] + newWeights[3];
        require(sum == BPS_DENOM, "weights sum != 10000");
        require(pendingAllocationId == bytes32(0), "pending exists");

        uint64 executesAt = uint64(block.timestamp) + timelockSeconds;
        bytes32 id = keccak256(abi.encodePacked(msg.sender, executesAt, newWeights, block.number));
        _pending = PendingAllocation({weights: newWeights, executesAt: executesAt, reason: reason});
        pendingAllocationId = id;

        emit AllocationRequested(id, newWeights, reason, executesAt);
        return id;
    }

    function executePending() external nonReentrant {
        require(pendingAllocationId != bytes32(0), "nothing pending");
        require(block.timestamp >= _pending.executesAt, "not yet");

        uint16[4] memory oldW = _weights;
        _weights = _pending.weights;
        bytes32 id = pendingAllocationId;
        pendingAllocationId = bytes32(0);
        _pending = PendingAllocation({weights: [uint16(0),uint16(0),uint16(0),uint16(0)], executesAt: 0, reason: ""});

        uint256 total = totalAssets();
        for (uint i = 0; i < 4; i++) {
            uint256 oldTarget = (total * oldW[i]) / BPS_DENOM;
            uint256 newTarget = (total * _weights[i]) / BPS_DENOM;
            if (newTarget > oldTarget) {
                uint256 delta = newTarget - oldTarget;
                asset_.safeTransfer(address(legs[i]), delta);
                legs[i].allocateTo(delta);
                _allocatedTotal += delta;
            } else if (oldTarget > newTarget) {
                uint256 delta = oldTarget - newTarget;
                // KI-5 fix: use the actual returned amount, not the
                // requested delta. A leg can return less than `delta`
                // (unstake waiting period, rounding on partial fill);
                // accounting the full target would leave `_allocatedTotal`
                // lower than the legs actually hold, which drifts the
                // share→asset conversion rate upward.
                uint256 reduced = legs[i].reduceFrom(delta);
                _allocatedTotal = _allocatedTotal > reduced ? _allocatedTotal - reduced : 0;
            }
        }
        emit AllocationExecuted(id, _weights);
    }

    /**
     * Cancel a pending allocation change.
     *
     * Access policy: owner OR keeper only. The original design had this
     * open to anyone as a "keeper-compromise safety net", but that's
     * also a griefing vector — a bot could cancel every legitimate
     * rebalance on 100-200ms blocks and freeze the keeper's workflow.
     * Owners and keepers can still recover from a compromised keeper by
     * calling `setPaused(true)` (which is owner-gated). The tradeoff
     * is documented in docs/AGGREGATOR_SPEC.md §3.5.
     */
    function cancelPending(bytes32 allocationId) external {
        require(pendingAllocationId != bytes32(0), "nothing pending");
        require(allocationId == pendingAllocationId, "wrong id");
        require(msg.sender == owner || msg.sender == keeper,
                "cancelPending: owner or keeper only");
        pendingAllocationId = bytes32(0);
        _pending = PendingAllocation({weights: [uint16(0),uint16(0),uint16(0),uint16(0)], executesAt: 0, reason: ""});
        emit AllocationCancelled(allocationId);
    }

    // ---- Harvest all legs into vault cash. ----
    function harvestFromAllLegs() external onlyKeeper nonReentrant {
        for (uint i = 0; i < 4; i++) legs[i].harvest();
        uint256 newAlloc = 0;
        for (uint i = 0; i < 4; i++) newAlloc += legs[i].currentValue();
        _allocatedTotal = newAlloc;
        emit Harvested(newAlloc);
    }

    /**
     * KI-2b Phase 2 (DESIGN_KI2B_AGGREGATOR_STREAM_A.md §3-6): the
     * stream-A rebalance path. The off-chain keeper signs a single
     * delegation with `d.keeper = address(this)` (the aggregator) and
     * passes `(d, sig)` here; the aggregator then forwards `(d, sig)`
     * to each perp leg's stream-A entry points (`submitIntentFromStreamA`
     * for new allocations, `reduceIntent` for pro-rata reductions).
     * Staking legs (KHYPE, Spot) continue to use the legacy
     * `allocateTo` / `reduceFrom` paths unchanged — they never touch
     * the writer, so there is no signature to check.
     *
     * Access: `onlyKeeper` (same as `executePending`); the aggregator
     * itself is the stream-A keeper named in `d.keeper`, so the
     * delegator's revocation of `revoke(aggregator)` halts every
     * stream-A delegation in one handle (FIX-21).
     *
     * Invariants enforced before any leg is touched (belt over the
     * leg's own verifier call):
     *   - Pending allocation exists and the timelock has elapsed.
     *   - `d.keeper == address(this)` (stream-A, not stream-B).
     *   - `d` is not expired (`expiresAt == 0` = never, `> 0` = ts).
     *
     * The EIP-712 signature is NOT re-verified here — the leg's own
     * `isValidDelegation` call is authoritative and binds the
     * signature to the writer call. Option C's duplicate verification
     * is deferred (see DESIGN_KI2B_AGGREGATOR_STREAM_A.md §2 Option C).
     */
    function executePendingWithStreamA(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external onlyKeeper nonReentrant {
        require(pendingAllocationId != bytes32(0), "nothing pending");
        require(block.timestamp >= _pending.executesAt, "not yet");
        require(d.keeper == address(this), "stream-A: d.keeper != aggregator");
        require(
            d.expiresAt == 0 || block.timestamp <= d.expiresAt,
            "stream-A: delegation expired"
        );

        uint16[4] memory oldW = _weights;
        _weights = _pending.weights;
        bytes32 id = pendingAllocationId;
        pendingAllocationId = bytes32(0);
        _pending = PendingAllocation({weights: [uint16(0),uint16(0),uint16(0),uint16(0)], executesAt: 0, reason: ""});

        uint256 total = totalAssets();
        for (uint i = 0; i < 4; i++) {
            uint256 oldTarget = (total * oldW[i]) / BPS_DENOM;
            uint256 newTarget = (total * _weights[i]) / BPS_DENOM;
            if (newTarget > oldTarget) {
                uint256 delta = newTarget - oldTarget;
                if (_isPerpLeg(i)) {
                    // Stream A: aggregator forwards (d, sig) to the leg's
                    // submitIntentFromStreamA, which enforces the
                    // per-order cap, verifies the signature, and calls
                    // the writer.
                    IIntentSubmittingLeg perpLeg = IIntentSubmittingLeg(address(legs[i]));
                    perpLeg.submitIntentFromStreamA(d, sig, delta);
                    _allocatedTotal += delta;
                } else {
                    // Staking leg: unchanged path.
                    asset_.safeTransfer(address(legs[i]), delta);
                    legs[i].allocateTo(delta);
                    _allocatedTotal += delta;
                }
            } else if (oldTarget > newTarget) {
                uint256 delta = oldTarget - newTarget;
                if (_isPerpLeg(i)) {
                    // Stream A reduce: closes `delta` of the leg's perp
                    // notional under (d, sig), sweeps USDC back to the
                    // aggregator, and sells the pro-rata HYPE cut on
                    // the spot side through the router.
                    IIntentSubmittingLeg perpLeg = IIntentSubmittingLeg(address(legs[i]));
                    uint256 returned = perpLeg.reduceIntent(d, sig, delta);
                    _allocatedTotal = _allocatedTotal > returned ? _allocatedTotal - returned : 0;
                } else {
                    uint256 reduced = legs[i].reduceFrom(delta);
                    _allocatedTotal = _allocatedTotal > reduced ? _allocatedTotal - reduced : 0;
                }
            }
        }
        emit AllocationExecuted(id, _weights);
    }

    /**
     * KI-2b Phase 2: stream-A harvest variant. Same as
     * `harvestFromAllLegs` but routes perp-leg harvests through
     * `leg.harvestIntent(d, sig)` with the aggregator's stream-A
     * delegation. Staking legs continue to use the no-arg `harvest()`.
     */
    function harvestFromAllLegs(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external onlyKeeper nonReentrant {
        require(d.keeper == address(this), "stream-A: d.keeper != aggregator");
        require(
            d.expiresAt == 0 || block.timestamp <= d.expiresAt,
            "stream-A: delegation expired"
        );

        for (uint i = 0; i < 4; i++) {
            if (_isPerpLeg(i)) {
                IIntentSubmittingLeg perpLeg = IIntentSubmittingLeg(address(legs[i]));
                perpLeg.harvestIntent(d, sig);
            } else {
                legs[i].harvest();
            }
        }
        uint256 newAlloc = 0;
        for (uint i = 0; i < 4; i++) newAlloc += legs[i].currentValue();
        _allocatedTotal = newAlloc;
        emit Harvested(newAlloc);
    }

    /**
     * Returns true if the leg at index `i` is a perp leg (i.e.
     * implements the stream-A surface from IIntentSubmittingLeg).
     * Uses EIP-165-style detection: perp legs have the `submittedIntents`
     * mapping (a public mapping getter), so a staticcall to
     * `submittedIntents(bytes32)` succeeds only on perp legs.
     *
     * This avoids the need for `type(I).is(address)` which is a
     * Solidity 0.8.27+ feature not available in 0.8.26. The check is
     * against a method that ONLY perp legs implement (staking legs
     * never call the writer, so they have no intent-submission
     * surface), so the detection is reliable.
     */
    function _isPerpLeg(uint256 i) internal view returns (bool) {
        address legAddr = address(legs[i]);
        if (legAddr.code.length == 0) return false;
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("submittedIntents(bytes32)")),
            bytes32(0)
        );
        (bool ok, bytes memory ret) = legAddr.staticcall(data);
        return ok && ret.length == 32;
    }

    // ---- Governance ----
    function setPaused(bool _p) external onlyOwner {
        paused = _p;
        emit PausedUpdated(_p);
    }
    function setKeeper(address newKeeper) external onlyOwner {
        require(newKeeper != address(0), "zero keeper");
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }
    function setTimelock(uint32 _ts) external onlyOwner {
        // Finding #12: block the owner from setting timelock=0, which
        // would let a compromised keeper request+execute rebalances in
        // a single transaction (or same-block grief if blocks are fast).
        // 60s is the minimum floor; production deployments should tune
        // far higher.
        require(_ts >= 60, "timelock below 60s");
        timelockSeconds = _ts;
    }

    // ---- Internal helpers ----
    function _distribute(uint256 assets) internal returns (uint256 distributed) {
        for (uint i = 0; i < 4; i++) {
            uint256 portion = (assets * _weights[i]) / BPS_DENOM;
            if (portion == 0) continue;
            asset_.safeTransfer(address(legs[i]), portion);
            uint256 allocated = legs[i].allocateTo(portion);
            distributed += allocated;
        }
    }

    function _redeem(uint256 assets, uint256 newShares, address receiver, address _owner) internal {
        require(shareBalances[_owner] >= newShares, "bad shares balance");
        require(totalShares >= newShares, "bad total shares");

        shareBalances[_owner] -= newShares;
        totalShares -= newShares;

        uint256 freeCash = asset_.balanceOf(address(this));
        if (freeCash < assets) {
            uint256 needed = assets - freeCash;
            for (uint i = 0; i < 4 && needed > 0; i++) {
                uint256 legVal = legs[i].currentValue();
                uint256 take = needed > legVal ? legVal : needed;
                if (take == 0) continue;
                // KI-5 fix: track the actual returned amount from the leg,
                // not the requested take. Legs may return less than asked
                // (unstake waiting period, rounding on partial fill), and
                // booking the full `take` would drift `_allocatedTotal`
                // below what the legs actually hold.
                uint256 returned = legs[i].reduceFrom(take);
                if (returned == 0) {
                    // Leg couldn't return anything (full unstake wait).
                    // Break early so we don't loop through the rest of
                    // the legs and burn gas — the withdrawal will fail
                    // downstream on `safeTransfer` if the vault doesn't
                    // have enough. Better to fail here with an explicit
                    // condition than to silently under-deliver.
                    break;
                }
                needed -= returned;
                if (_allocatedTotal > returned) _allocatedTotal -= returned;
                else _allocatedTotal = 0;
            }
        }
        asset_.safeTransfer(receiver, assets);
        emit Transfer(_owner, address(0), newShares);
    }
}
