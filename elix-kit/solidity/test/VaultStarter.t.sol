// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20.sol";
import {VaultStarter} from "../src/examples/VaultStarter.sol";

/// @dev Minimal ERC-20 for testing. Always returns true from
///      approve/transfer/transferFrom. No events. No decimals — the
///      vault doesn't care.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        name = "Mock";
        symbol = "MOCK";
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "mock: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "mock: balance");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "mock: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract VaultStarterTest is Test {
    MockERC20 token;
    VaultStarter vault;

    address alice;
    address bob;
    address owner;

    uint256 constant INIT_APY_BPS = 1_000; // 10% APY
    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    function setUp() public {
        alice = address(0xA11CE);
        bob = address(0xB0B);
        owner = address(0x0cD0);

        vm.prank(owner);
        token = new MockERC20();

        vm.startPrank(owner);
        vault = new VaultStarter(address(token), owner, INIT_APY_BPS, "Elysium Vault", "eVL");
        vm.stopPrank();

        vm.startPrank(alice);
        token.mint(alice, 1_000_000 ether);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_DepositMintsSharesAndTransfersTokens() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        assertEq(token.balanceOf(address(vault)), 1_000 ether);
        assertEq(vault.balanceOf(alice), 1_000 ether);
        assertEq(vault.totalSharesIssued(), 1_000 ether);
        assertEq(vault.totalAssetsAccrued(), 1_000 ether);
    }

    function test_DepositOfZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VaultStarter: zero assets"));
        vault.deposit(0, alice);
    }

    function test_DepositToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VaultStarter: zero receiver"));
        vault.deposit(1 ether, address(0));
    }

    function test_WithdrawBurnsSharesAndReturnsTokens() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        vm.prank(alice);
        vault.withdraw(250 ether, alice, alice);

        // Alice started with 1_000_000, deposited 1_000 → 999_000,
        // then received 250 back → 999_250.
        assertEq(token.balanceOf(alice), 999_000 ether + 250 ether);

        // Shares burned = 250 * totalSharesIssued / totalAssets.
        // A tiny amount of interest has accrued between deposit and
        // withdraw, so the burn is marginally under 250 shares.
        uint256 sharesAfter = vault.balanceOf(alice);
        assertGe(sharesAfter, 749 ether);
        assertLe(sharesAfter, 750 ether);
        // Alice is the only depositor, so her balance IS the total.
        assertEq(vault.totalSharesIssued(), sharesAfter);
    }

    function test_PreviewRedeemSanity() public {
        // Empty vault: 1 share <-> 1 unit of the asset.
        assertEq(vault.previewRedeem(1 ether), 1 ether);
        assertEq(vault.previewDeposit(1 ether), 1 ether);
    }

    function test_PreviewRedeemAfterDepositAndInterest() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        // Move time forward 365 days = 1 full year at 10% APY.
        vm.warp(block.timestamp + SECONDS_PER_YEAR);

        // totalAssets should now be ~1100. previewRedeem of the
        // full share balance should return ~1100 units of the asset.
        uint256 predicted = vault.previewRedeem(vault.balanceOf(alice));
        assertGt(predicted, 1_090 ether);
        assertLt(predicted, 1_110 ether);
    }

    function test_SetTargetApyBpsIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VaultStarter: only owner"));
        vault.setTargetApyBps(500);
    }

    function test_SetTargetApyBpsOwner() public {
        vm.prank(owner);
        vault.setTargetApyBps(500);
        assertEq(vault.targetApyBps(), 500);
    }

    function test_SetTargetApyBpsRejectsAbove100Percent() public {
        vm.prank(owner);
        vm.expectRevert(bytes("VaultStarter: apy > 100%"));
        vault.setTargetApyBps(10_001);
    }

    function test_ConstructorRejectsZeroAsset() public {
        vm.expectRevert(bytes("VaultStarter: zero asset"));
        new VaultStarter(address(0), owner, INIT_APY_BPS, "Elysium Vault", "eVL");
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(bytes("VaultStarter: zero owner"));
        new VaultStarter(address(token), address(0), INIT_APY_BPS, "Elysium Vault", "eVL");
    }
}
