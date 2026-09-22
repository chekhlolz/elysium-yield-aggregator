// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";

// ---- Minimal ERC-20 (only what the aggregator calls). ----
interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

// ---- Safe ERC-20 helpers. ----
library SafeERC20 {
    function safeTransfer(IERC20Minimal tok, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(abi.encodeCall(
            IERC20Minimal.transfer, (to, v)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 transfer failed");
    }

    function safeTransferFrom(IERC20Minimal tok, address from, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(abi.encodeCall(
            IERC20Minimal.transferFrom, (from, to, v)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 transferFrom failed");
    }

    function safeApprove(IERC20Minimal tok, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(abi.encodeCall(
            IERC20Minimal.approve, (to, v)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 approve failed");
    }
}

/**
 * @title YieldAggregator
 * @notice ERC-4626-style vault with regime-driven allocation across four
 *         yield legs. Full design: docs/AGGREGATOR_SPEC.md.
 *
 * Architecture:
 *   - 4 yield legs (spot, kHYPE, perp funding, basis hedge) — each
 *     implements IYieldLeg, so the aggregator treats them as opaque.
 *   - Allocation weights are basis points (sum = 10_000), set by keeper
 *     via requestAllocation + executePending with a configurable timelock.
 *   - `cancelPending` is open — any caller can abort a pending change
 *     during the timelock, which is the safety net against a compromised
 *     keeper.
 *
 * Not shipped to mainnet; this is a reference implementation for the
 * Elysium builder proposal. Production will add governance, accounting
 * snapshots, and leg-specific safety checks.
 */
contract YieldAggregator {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant BPS_DENOM = 10_000;

    // ---- Core storage ----
    IERC20Minimal public immutable asset_;
    IYieldLeg[4] public legs_;

    mapping(address => uint256) public balances;
    uint256 public totalShares;
    uint256 private _allocatedTotal;

    uint16[4] private _weights;

    uint32 public timelockSeconds;
    address public keeper;
    address public owner;
    bool public paused;

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
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier notPaused() { require(!paused, "paused"); _; }

    // ---- Constructor ----
    constructor(
        IERC20Minimal _asset,
        address _keeper,
        IYieldLeg[4] memory _legs,
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
            require(address(_legs[i]) != address(0), "zero leg");
            legs_[i] = _legs[i];
        }
    }

    // ---- Views ----
    function asset() external view returns (address) { return address(asset_); }
    function weights() external view returns (uint16[4] memory) { return _weights; }

    function currentValueOfLeg(uint256 i) public view returns (uint256) {
        require(i < 4, "bad leg index");
        return legs_[i].currentValue();
    }

    function totalLegValue() public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < 4; i++) total += legs_[i].currentValue();
        return total;
    }

    function totalAssets() public view returns (uint256) {
        return totalLegValue() + asset_.balanceOf(address(this));
    }

    function currentApyBps() external view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < 4; i++) total += legs_[i].expectedApy() * _weights[i];
        return total / BPS_DENOM;
    }

    // ---- ERC-4626 accounting ----
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalShares == 0) return assets; // 1:1 bootstrap
        return (assets * totalShares) / _totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalShares == 0) return shares; // 1:1 bootstrap
        return (shares * _totalAssets()) / totalShares;
    }

    function _totalAssets() internal view returns (uint256) {
        return totalAssets();
    }

    // ---- Deposit / mint ----
    function deposit(uint256 assets, address receiver) external notPaused returns (uint256 shares) {
        require(assets > 0, "zero deposit");
        shares = convertToShares(assets);
        require(shares > 0, "dust shares");

        asset_.safeTransferFrom(msg.sender, address(this), assets);

        totalShares += shares;
        balances[receiver] += shares;

        // Distribute the new assets across legs per current weights.
        uint256 distributed = _distribute(assets);
        _allocatedTotal += distributed;

        // Any remainder stays in the vault as free cash.

        emit Transfer(address(0), receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external notPaused returns (uint256 assets) {
        require(shares > 0, "zero shares");
        assets = convertToAssets(shares);
        require(assets > 0, "dust assets");

        asset_.safeTransferFrom(msg.sender, address(this), assets);
        totalShares += shares;
        balances[receiver] += shares;

        uint256 distributed = _distribute(assets);
        _allocatedTotal += distributed;

        emit Transfer(address(0), receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ---- Withdraw / redeem ----
    function withdraw(uint256 assets, address receiver, address owner_)
        external notPaused returns (uint256 shares)
    {
        require(assets > 0, "zero withdrawal");
        shares = convertToShares(assets);
        require(shares > 0, "dust shares");

        if (msg.sender != owner_) {
            uint256 allowed = asset_.allowance(owner_, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= assets, "insufficient token allowance");
                asset_.safeTransferFrom(owner_, address(this), assets);
                asset_.safeApprove(msg.sender, allowed - assets);
            }
        }

        _redeem(assets, shares, receiver, owner_);
        emit Withdraw(msg.sender, owner_, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        external notPaused returns (uint256 assets)
    {
        require(shares > 0, "zero redeem");
        assets = convertToAssets(shares);
        require(assets > 0, "dust assets");

        if (msg.sender != owner_) {
            uint256 current = asset_.allowance(owner_, msg.sender);
            require(current >= shares, "insufficient share allowance");
            asset_.safeApprove(msg.sender, current - shares);
        }

        _redeem(assets, shares, receiver, owner_);
        emit Withdraw(msg.sender, owner_, receiver, assets, shares);
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

    function executePending() external {
        require(pendingAllocationId != bytes32(0), "nothing pending");
        require(block.timestamp >= _pending.executesAt, "not yet");

        uint16[4] memory oldW = _weights;
        _weights = _pending.weights;
        bytes32 id = pendingAllocationId;
        pendingAllocationId = bytes32(0);
        _pending = PendingAllocation({weights: [uint16(0),uint16(0),uint16(0),uint16(0)], executesAt: 0, reason: ""});

        // Rebalance each leg.
        uint256 total = totalAssets();
        for (uint i = 0; i < 4; i++) {
            uint256 oldTarget = (total * oldW[i]) / BPS_DENOM;
            uint256 newTarget = (total * _weights[i]) / BPS_DENOM;
            if (newTarget > oldTarget) {
                uint256 delta = newTarget - oldTarget;
                asset_.safeTransfer(address(legs_[i]), delta);
                legs_[i].allocateTo(delta);
                _allocatedTotal += delta;
            } else if (oldTarget > newTarget) {
                uint256 delta = oldTarget - newTarget;
                legs_[i].reduceFrom(delta);
                _allocatedTotal = _allocatedTotal > delta ? _allocatedTotal - delta : 0;
            }
        }

        emit AllocationExecuted(id, _weights);
    }

    /** Open to anyone — this is the keeper-compromise safety net. */
    function cancelPending(bytes32 allocationId) external {
        require(pendingAllocationId != bytes32(0), "nothing pending");
        require(allocationId == pendingAllocationId, "wrong id");
        pendingAllocationId = bytes32(0);
        _pending = PendingAllocation({weights: [uint16(0),uint16(0),uint16(0),uint16(0)], executesAt: 0, reason: ""});
        emit AllocationCancelled(allocationId);
    }

    // ---- Harvest all legs into vault cash. ----
    function harvestFromAllLegs() external onlyKeeper {
        for (uint i = 0; i < 4; i++) {
            legs_[i].harvest();
            _allocatedTotal -= legs_[i].currentValue();
            // Recompute after the loop (below).
        }
        // Recompute _allocatedTotal from legs.
        uint256 newAlloc = 0;
        for (uint i = 0; i < 4; i++) newAlloc += legs_[i].currentValue();
        _allocatedTotal = newAlloc;
        emit Harvested(newAlloc);
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
        timelockSeconds = _ts;
    }

    // ---- Internal helpers ----
    function _distribute(uint256 assets) internal returns (uint256 distributed) {
        for (uint i = 0; i < 4; i++) {
            uint256 portion = (assets * _weights[i]) / BPS_DENOM;
            if (portion == 0) continue;
            // Send funds to the leg's contract so it can hold them.
            asset_.safeTransfer(address(legs_[i]), portion);
            uint256 allocated = legs_[i].allocateTo(portion);
            distributed += allocated;
        }
    }

    function _redeem(uint256 assets, uint256 shares, address receiver, address owner_) internal {
        require(balances[owner_] >= shares, "bad shares balance");
        require(totalShares >= shares, "bad total shares");

        balances[owner_] -= shares;
        totalShares -= shares;

        // Pull cash from legs until vault has enough.
        uint256 freeCash = asset_.balanceOf(address(this));
        if (freeCash < assets) {
            uint256 needed = assets - freeCash;
            for (uint i = 0; i < 4 && needed > 0; i++) {
                uint256 legVal = legs_[i].currentValue();
                uint256 take = needed > legVal ? legVal : needed;
                if (take == 0) continue;
                legs_[i].reduceFrom(take);
                needed -= take;
                if (_allocatedTotal > take) _allocatedTotal -= take;
                else _allocatedTotal = 0;
            }
        }
        asset_.safeTransfer(receiver, assets);

        emit Transfer(owner_, address(0), shares);
    }
}
