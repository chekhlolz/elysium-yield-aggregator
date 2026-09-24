// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20Minimal, SafeERC20} from "../interfaces/IERC20.sol";

/**
 * @title VaultStarter
 * @notice Minimal ERC-4626-shaped vault that accepts an ERC-20 (HYPE in the
 *         real story, any token here) and accrues simple interest at a
 *         configurable `targetApyBps` set by the owner.
 *
 * @dev TEACHING TEMPLATE. Not for production. Deliberate simplifications:
 *
 *   - Interest accrues linearly on the current principal; no compounding.
 *     Real vaults that layer yield on yield should compounding-accrue.
 *   - No management fee, no performance fee, no timelock, no governance.
 *     Add these when shipping to mainnet.
 *   - Owner is set at construction and is immutable. Real vaults should
 *     support `transferOwnership` with a timelock.
 *   - No share rounding hardening: first depositor can front-run the
 *     share exchange rate (the classic ERC-4626 dust attack). Add a
 *     "minimum first deposit" guard before deployment.
 *   - `targetApyBps` is capped at 10000 (100% APY). Bigger numbers
 *     are almost certainly a bug.
 *
 * Share accounting:
 *
 *   `totalSharesIssued` is the outstanding share supply.
 *   `totalAssetsAccrued` is the vault's asset position at the last
 *   accrual tick, including all interest earned since inception.
 *
 *   `totalAssets()` = `totalAssetsAccrued` + linear interest since
 *   `lastAccrual`, computed at the current `targetApyBps`.
 *
 *   All mutations accrue BEFORE computing share/asset conversions, so
 *   neither side can front-run the exchange rate by timing their call.
 */
contract VaultStarter {
    // ---- Constants ----

    uint256 public constant MAX_ASSET = type(uint256).max;
    uint256 public constant MAX_SHARES = type(uint256).max;

    /// 365 days in seconds. Real chains occasionally want 366 or
    /// `365.25 * 86400`; simple interest makes the difference moot for
    /// a teaching vault.
    uint256 public constant SECONDS_PER_YEAR = 31_536_000;

    uint8 public constant decimals = 18;

    // ---- Immutable config ----

    /// The underlying asset. On Elysium, this is HYPE. In tests, it is
    /// whatever token the test deploys.
    IERC20Minimal public immutable asset;

    /// The vault owner. Owns `setTargetApyBps`. Immutable by design;
    /// real vaults should use `Ownable2Step` with a timelock.
    address public immutable owner;

    string public name;
    string public symbol;

    // ---- Mutable state ----

    /// Target annual yield in basis points. `10000` = 100% APY,
    /// `189` = 1.89% APY (roughly HYPE native staking).
    uint256 public targetApyBps;

    /// Last block timestamp we accrued interest at.
    uint256 public lastAccrual;

    /// Vault asset position at `lastAccrual`, including all interest
    /// earned since inception. Updated on every state-changing call.
    uint256 public totalAssetsAccrued;

    /// Total outstanding shares. Updated on deposit / withdraw.
    uint256 public totalSharesIssued;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---- Events ----

    event Transfer(address indexed from, address indexed to, uint256 shares);
    event Approval(address indexed owner, address indexed spender, uint256 shares);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event TargetApyBpsSet(uint256 prev, uint256 next);

    // ---- Modifiers ----

    modifier onlyOwner() {
        require(msg.sender == owner, "VaultStarter: only owner");
        _;
    }

    // ---- Constructor ----

    constructor(address _asset, address _owner, uint256 _targetApyBps, string memory _name, string memory _symbol) {
        require(_asset != address(0), "VaultStarter: zero asset");
        require(_owner != address(0), "VaultStarter: zero owner");
        require(_targetApyBps <= 10_000, "VaultStarter: apy > 100%");
        asset = IERC20Minimal(_asset);
        owner = _owner;
        name = _name;
        symbol = _symbol;
        targetApyBps = _targetApyBps;
        lastAccrual = block.timestamp;
        totalAssetsAccrued = 0;
        totalSharesIssued = 0;
        emit TargetApyBpsSet(0, _targetApyBps);
    }

    // ---- Admin ----

    /**
     * @dev Owner-gated. Set the target annual yield in bps.
     *
     * The rate change takes effect on the NEXT accrual tick: the
     * already-accrued principal is not retroactively re-priced.
     */
    function setTargetApyBps(uint256 newBps) external onlyOwner {
        require(newBps <= 10_000, "VaultStarter: apy > 100%");
        uint256 prev = targetApyBps;
        targetApyBps = newBps;
        emit TargetApyBpsSet(prev, newBps);
    }

    // ---- Views ----

    /**
     * @dev Total assets managed by the vault right now.
     *
     *   `totalAssets() = totalAssetsAccrued + principal * apyBps * elapsed / (10_000 * SECONDS_PER_YEAR)`
     *
     * Pure view; accrues in-memory only. State-mutating calls also
     * update the on-chain state via `_accrue()`.
     */
    function totalAssets() public view returns (uint256) {
        uint256 now = block.timestamp;
        if (lastAccrual >= now) return totalAssetsAccrued;
        uint256 elapsed = now - lastAccrual;
        uint256 interest = (totalAssetsAccrued * targetApyBps * elapsed) / (10_000 * SECONDS_PER_YEAR);
        return totalAssetsAccrued + interest;
    }

    function totalSupply() external view returns (uint256) {
        return totalSharesIssued;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalSharesIssued == 0) return assets;
        return assets * totalSharesIssued / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSharesIssued == 0) return shares;
        return shares * totalAssets() / totalSharesIssued;
    }

    // ERC-4626 preview surface. Without fee logic, `previewX == convertToY`.
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

    // ---- Share transfers ----

    function transfer(address to, uint256 shares) external returns (bool) {
        require(to != address(0), "VaultStarter: zero to");
        require(to != address(this), "VaultStarter: to vault");
        require(balanceOf[msg.sender] >= shares, "VaultStarter: balance");
        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
        emit Transfer(msg.sender, to, shares);
        return true;
    }

    function transferFrom(address from, address to, uint256 shares) external returns (bool) {
        require(to != address(0), "VaultStarter: zero to");
        require(to != address(this), "VaultStarter: to vault");
        _spendShareAllowance(from, msg.sender, shares);
        require(balanceOf[from] >= shares, "VaultStarter: balance");
        balanceOf[from] -= shares;
        balanceOf[to] += shares;
        emit Transfer(from, to, shares);
        return true;
    }

    function approve(address spender, uint256 shares) external returns (bool) {
        require(spender != address(0), "VaultStarter: zero spender");
        allowance[msg.sender][spender] = shares;
        emit Approval(msg.sender, spender, shares);
        return true;
    }

    function increaseAllowance(address spender, uint256 added) external returns (bool) {
        allowance[msg.sender][spender] += added;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtracted) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        require(current >= subtracted, "VaultStarter: allowance");
        allowance[msg.sender][spender] = current - subtracted;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    // ---- Deposit / withdraw ----

    /**
     * @dev Deposit `assets` of the underlying, mint shares to `receiver`.
     *
     * Order of operations (deliberate):
     *   1. Accrue interest on existing principal.
     *   2. Compute shares via the post-accrual rate.
     *   3. Pull the asset in via `transferFrom`.
     *   4. Credit the shares to `receiver`.
     *
     * If anything fails mid-way, the whole tx reverts (Solidity 0.8
     * default) — so there is no window where the vault has assets but
     * has not minted shares, or vice versa.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(receiver != address(0), "VaultStarter: zero receiver");
        require(assets > 0, "VaultStarter: zero assets");
        _accrue();
        shares = convertToShares(assets);
        require(shares > 0, "VaultStarter: zero shares");
        SafeERC20.safeTransferFrom(asset, msg.sender, address(this), assets);
        balanceOf[receiver] += shares;
        totalSharesIssued += shares;
        totalAssetsAccrued += assets;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(receiver != address(0), "VaultStarter: zero receiver");
        require(shares > 0, "VaultStarter: zero shares");
        _accrue();
        assets = convertToAssets(shares);
        require(assets > 0, "VaultStarter: zero assets");
        SafeERC20.safeTransferFrom(asset, msg.sender, address(this), assets);
        balanceOf[receiver] += shares;
        totalSharesIssued += shares;
        totalAssetsAccrued += assets;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        require(receiver != address(0), "VaultStarter: zero receiver");
        require(assets > 0, "VaultStarter: zero assets");
        _accrue();
        shares = convertToShares(assets);
        require(shares > 0, "VaultStarter: zero shares");
        _spendShareAllowance(owner_, msg.sender, shares);
        require(balanceOf[owner_] >= shares, "VaultStarter: balance");
        balanceOf[owner_] -= shares;
        totalSharesIssued -= shares;
        totalAssetsAccrued -= assets;
        SafeERC20.safeTransfer(asset, receiver, assets);
        emit Withdraw(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        require(receiver != address(0), "VaultStarter: zero receiver");
        require(shares > 0, "VaultStarter: zero shares");
        _accrue();
        assets = convertToAssets(shares);
        require(assets > 0, "VaultStarter: zero assets");
        _spendShareAllowance(owner_, msg.sender, shares);
        require(balanceOf[owner_] >= shares, "VaultStarter: balance");
        balanceOf[owner_] -= shares;
        totalSharesIssued -= shares;
        totalAssetsAccrued -= assets;
        SafeERC20.safeTransfer(asset, receiver, assets);
        emit Withdraw(msg.sender, receiver, assets, shares);
    }

    // ---- Internals ----

    /**
     * @dev Push the on-chain principal forward by the elapsed time
     *     since the last accrual. Called at the start of every
     *     state-changing operation.
     *
     * Idempotent: if `block.timestamp` has not advanced past
     * `lastAccrual`, this is a no-op.
     */
    function _accrue() internal {
        uint256 now = block.timestamp;
        if (lastAccrual >= now) return;
        uint256 elapsed = now - lastAccrual;
        uint256 interest = (totalAssetsAccrued * targetApyBps * elapsed) / (10_000 * SECONDS_PER_YEAR);
        totalAssetsAccrued += interest;
        lastAccrual = now;
    }

    /**
     * @dev Check the share-level allowance when moving shares on
     *     behalf of `holder` to `msg.sender`'s beneficiary.
     *
     * No-op when the caller is the holder themselves, or when
     * `msg.sender` is the beneficiary (i.e., the standard direct
     * call shape). Otherwise decrement the standard `allowance`
     * balance (which tracks share units for `transferFrom`,
     * `withdraw`, `redeem`).
     */
    function _spendShareAllowance(address holder, address spender, uint256 amount) internal {
        if (spender == holder || spender == msg.sender) return;
        if (allowance[holder][spender] == type(uint256).max) return;
        uint256 current = allowance[holder][spender];
        require(current >= amount, "VaultStarter: allowance");
        allowance[holder][spender] = current - amount;
        emit Approval(holder, spender, allowance[holder][spender]);
    }
}
