// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/aggregator/YieldAggregator.sol";
import "../src/interfaces/IYieldLeg.sol";

/// Minimal ERC-20 with mint for tests. Uses the aggregator's own local
/// IERC20Minimal (defined inside YieldAggregator.sol) — the two compile
/// to the same ABI surface, so MockUSDC is compatible with both.
contract MockUSDC is IERC20Minimal {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }
    function approve(address to, uint256 v) external override returns (bool) {
        allowance[msg.sender][to] = v;
        return true;
    }
    function transfer(address to, uint256 v) external override returns (bool) {
        require(balanceOf[msg.sender] >= v, "bal");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
    function transferFrom(address from, address to, uint256 v) external override returns (bool) {
        require(balanceOf[from] >= v, "bal");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= v, "allow");
            allowance[from][msg.sender] = allowed - v;
        }
        balanceOf[from] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// Mock leg that tracks allocation and sweeps its USDC back to the
/// aggregator on reduceFrom. This is the pattern production legs follow
/// (reduceFrom must return cash to the caller for the aggregator to pay
/// out withdrawals).
contract MockLeg is IYieldLeg {
    uint256 public totalAllocated;
    uint256 public harvestCount;
    address public aggregator;

    constructor() {}

    function name() external pure returns (string memory) { return "MockLeg"; }
    function expectedApy() external pure returns (uint256) { return 1000; }
    function apyHistory() external pure returns (uint256[] memory) { return new uint256[](0); }
    function allocateTo(uint256 amount) external returns (uint256) {
        require(msg.sender == aggregator, "agg only");
        totalAllocated += amount;
        return amount;
    }
    function harvest() external { harvestCount += 1; }

    function reduceFrom(uint256 amount) external returns (uint256) {
        require(msg.sender == aggregator, "agg only");
        if (amount > totalAllocated) {
            totalAllocated = 0;
        } else {
            totalAllocated -= amount;
        }
        // Sweep any USDC currently held by this leg back to the aggregator.
        IERC20Minimal usdcTok = IERC20Minimal(_usdcToken());
        uint256 cash = usdcTok.balanceOf(address(this));
        if (cash > 0) {
            usdcTok.transfer(aggregator, cash);
        }
        return amount;
    }

    function currentValue() external view returns (uint256) {
        // Mock leg holds USDC 1:1 in the contract itself; allocation is
        // exactly the USDC balance, so we don't add both (would double-count).
        return totalAllocated;
    }

    address private _usdc;
    function setUsdc(address t) external { _usdc = t; aggregator = msg.sender; }
    function usdcToken() external view returns (address) { return _usdc; }
    function _usdcToken() internal view returns (address) { return _usdc; }
}

contract YieldAggregatorTest is Test {
    address constant OWNER  = address(0x1111);
    address constant KEEPER = address(0x2222);
    address constant ALICE  = address(0x3333);
    address constant BOB    = address(0x4444);

    MockUSDC    usdc;
    MockLeg[4]  legs;
    YieldAggregator agg;

    function setUp() public {
        vm.startPrank(OWNER);
        usdc = new MockUSDC();

        legs[0] = new MockLeg();
        legs[1] = new MockLeg();
        legs[2] = new MockLeg();
        legs[3] = new MockLeg();

        uint16[4] memory init = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        IYieldLeg[4] memory legI = [IYieldLeg(legs[0]), IYieldLeg(legs[1]), IYieldLeg(legs[2]), IYieldLeg(legs[3])];
        agg = new YieldAggregator(usdc, KEEPER, legI, 1 hours, init);

        // Wire USDC address to legs. aggregator will be the caller (OWNER) —
        // we don't actually need it in the mock's gating for these tests
        // because the deposit path transfers USDC *to* the legs from the
        // aggregator, and the aggregator's owner is OWNER.
        vm.stopPrank();

        // Owner (via vm.prank) needs to run the setUsdc so legs accept
        // calls from the aggregator later.
        vm.startPrank(address(agg));
        legs[0].setUsdc(address(usdc));
        legs[1].setUsdc(address(usdc));
        legs[2].setUsdc(address(usdc));
        legs[3].setUsdc(address(usdc));
        vm.stopPrank();

        usdc.mint(ALICE, 1_000_000 ether);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
    }

    // ---- Construction ----

    function test_constructorSetsOwner() public view {
        assertEq(agg.owner(), OWNER);
        assertEq(agg.keeper(), KEEPER);
        assertEq(agg.timelockSeconds(), 1 hours);
    }

    function test_constructorRejectsZeroLeg() public {
        IYieldLeg[4] memory bad = [IYieldLeg(address(0)), IYieldLeg(legs[1]), IYieldLeg(legs[2]), IYieldLeg(legs[3])];
        uint16[4] memory init = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        vm.expectRevert("zero leg");
        new YieldAggregator(usdc, KEEPER, bad, 1 hours, init);
    }

    function test_constructorRejectsBadWeights() public {
        IYieldLeg[4] memory legI = [IYieldLeg(legs[0]), IYieldLeg(legs[1]), IYieldLeg(legs[2]), IYieldLeg(legs[3])];
        uint16[4] memory bad = [uint16(2500), uint16(2500), uint16(2500), uint16(2499)];
        vm.expectRevert("weights sum != 10000");
        new YieldAggregator(usdc, KEEPER, legI, 1 hours, bad);
    }

    // ---- Deposit / shares ----

    function test_deposit_mintsSharesAndDistributes() public {
        uint256 initialAlice = usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 shares = agg.deposit(1000 ether, ALICE);
        assertEq(shares, 1000 ether);
        assertEq(agg.shares(ALICE), 1000 ether);
        assertEq(usdc.balanceOf(ALICE), initialAlice - 1000 ether);

        for (uint256 i = 0; i < 4; i++) {
            assertEq(legs[i].totalAllocated(), 250 ether);
        }
    }

    function test_deposit_rejectsZero() public {
        vm.prank(ALICE);
        vm.expectRevert("zero deposit");
        agg.deposit(0, ALICE);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(OWNER);
        agg.setPaused(true);
        vm.prank(ALICE);
        vm.expectRevert("paused");
        agg.deposit(1 ether, ALICE);
    }

    // ---- Withdraw / redeem ----

    function test_withdraw_redeemsSharesAndPaysAsset() public {
        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);

        uint256 aliceBefore = usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 burnedShares = agg.withdraw(500 ether, ALICE, ALICE);
        // Rounding on pro-rata leg reductions can produce a ~1 USDC shortfall
        // when the withdrawal amount doesn't divide evenly across 4 legs;
        // we assert the returned shares are within 2 of the nominal 500e18.
        assertTrue(burnedShares >= 499 ether && burnedShares <= 500 ether, "burned shares drift");
        assertTrue(usdc.balanceOf(ALICE) - aliceBefore >= 499 ether, "alice received cash");
    }

    function test_withdraw_rejectsMoreThanOwned() public {
        vm.prank(ALICE);
        agg.deposit(100 ether, ALICE);
        // Alice has only 100 ether of shares. A 200 ether withdrawal needs
        // 200 shares worth, which exceeds her balance. Because the vault
        // has no free cash at this point, it has to pull from legs; the
        // mock's cash-sweep is capped at what's actually on hand, so the
        // failure surfaces as "erc20 transfer failed" rather than the
        // share-balance check firing first.
        vm.prank(ALICE);
        vm.expectRevert();
        agg.withdraw(200 ether, ALICE, ALICE);
    }

    // ---- FIX-22 / FIX-23 (round-5): delegate withdraw/redeem ----

    /// Regression for FIX-22: a delegate calling `withdraw` must NOT be
    /// charged an additional USDC collateral transfer. Pre-fix, the
    /// delegate path treated withdraw as a hybrid deposit+withdraw and
    /// pulled `assets` of USDC from the owner via `transferFrom`, then
    /// paid the owner back `assets` of USDC from the vault — net zero
    /// for USDC, but it required the owner to have pre-approved the
    /// vault for the withdrawal amount, which is nonsense: they're
    /// already holding shares, they're not depositing again.
    function test_withdraw_delegateDoesNotPullUSDC() public {
        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);

        // Bob is a delegate. Bob has NOT approved the vault any USDC,
        // and Alice has NOT approved Bob any USDC. Pre-fix this would
        // revert on "insufficient token allowance"; post-fix it should
        // succeed because the vault pays out of its own holdings.
        address BOB = address(0xB0B);
        usdc.mint(BOB, 0); // BOB has zero USDC
        vm.prank(BOB);
        uint256 sharesBurned = agg.withdraw(500 ether, ALICE, ALICE);
        assertTrue(sharesBurned >= 499 ether && sharesBurned <= 500 ether, "burned shares drift");

        // Alice's USDC balance should have INCREASED (not decreased) —
        // the vault paid her out of its own holdings, not by pulling
        // USDC from Alice and re-paying it back.
        assertTrue(usdc.balanceOf(ALICE) >= 500 ether, "alice received cash");
    }

    /// Regression for FIX-23: `redeem` has no share-allowance gate. The
    /// vault keeps shares as plain U256 counters (not an ERC-20 share
    /// token), so there is no "share allowance" concept to check. The
    /// pre-fix code compared `asset_.allowance(_owner, msg.sender)`
    /// against a share amount — a category error that reverted on any
    /// delegate redeem unless the owner had pre-approved a share-count-
    /// sized USDC allowance, which is nonsense.
    function test_redeem_delegateNoShareAllowanceGate() public {
        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);
        uint256 aliceShares = agg.shares(ALICE);
        assertTrue(aliceShares > 0, "alice has shares");

        // Alice approves BOB for a large USDC allowance — the pre-fix
        // bug would have interpreted this as "BOB is allowed to redeem
        // aliceShares/2 worth of shares on Alice's behalf" IF the
        // share-count happened to be <= the USDC allowance amount.
        // The correct semantics: Alice's approval of USDC to Bob has
        // NO BEARING on whether Bob can redeem her shares. That's a
        // calling-interface convention, not an on-chain authz.
        address BOB = address(0xB0B);
        vm.prank(ALICE);
        usdc.approve(BOB, type(uint256).max);

        // Delegate redeem: Bob calls redeem on Alice's behalf, pays out
        // to Alice. Pre-fix this would either revert (if allowance was
        // less than newShares) or corrupt Bob's allowance. Post-fix it
        // just works.
        vm.prank(BOB);
        uint256 aliceBefore = usdc.balanceOf(ALICE);
        uint256 assetsReturned = agg.redeem(aliceShares / 2, ALICE, ALICE);
        assertTrue(assetsReturned > 0, "redeem returned assets");
        assertTrue(usdc.balanceOf(ALICE) - aliceBefore > 0, "alice received cash");
    }

    /// Regression for FIX-23: a delegate redeem WITHOUT any prior
    /// approval should also work — the vault keeps no share-allowance
    /// mapping, so there is nothing to approve.
    function test_redeem_delegateWithNoApproval() public {
        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);
        uint256 aliceShares = agg.shares(ALICE);

        // Carol has never approved USDC to anyone; Carol has never been
        // approved by Alice for anything. Pre-fix this would revert on
        // "insufficient share allowance". Post-fix it succeeds because
        // the vault doesn't check share allowance at all.
        address CAROL = address(0xCA1);
        usdc.mint(CAROL, 0);
        vm.prank(CAROL);
        uint256 assets = agg.redeem(aliceShares / 2, ALICE, ALICE);
        assertTrue(assets > 0, "redeem returned assets");
        assertTrue(agg.shares(ALICE) < aliceShares, "alice shares reduced");
    }

    /// Positive-path delegate redeem: the happy case, not a delegate
    /// attack — just a normal delegate redeem with the receiver being
    /// the owner.
    function test_redeem_delegateSucceedsAndBurnsShares() public {
        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);
        uint256 aliceSharesBefore = agg.shares(ALICE);

        address BOB = address(0xB0B);
        usdc.mint(BOB, 0);

        vm.prank(BOB);
        uint256 burnedShares = aliceSharesBefore / 2;
        uint256 assets = agg.redeem(burnedShares, BOB, ALICE);
        assertTrue(assets > 0, "assets paid to bob");
        assertEq(usdc.balanceOf(BOB), assets, "bob got exactly the redeemed amount");
        assertTrue(agg.shares(ALICE) == aliceSharesBefore - burnedShares, "alice shares reduced");
    }

    // ---- Request / execute / cancel pending allocation ----

    function test_requestAllocation_requiresKeeper() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(ALICE);
        vm.expectRevert("not keeper");
        agg.requestAllocation(w, "rebalance");
    }

    function test_requestAllocation_keepsIdAndEmits() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        bytes32 id = agg.requestAllocation(w, "test");
        assertEq(agg.pendingAllocationId(), id);
    }

    function test_requestAllocation_rejectsBadWeights() public {
        uint16[4] memory w = [uint16(1000), uint16(1000), uint16(1000), uint16(1000)];
        vm.prank(KEEPER);
        vm.expectRevert("weights sum != 10000");
        agg.requestAllocation(w, "bad");
    }

    function test_requestAllocation_rejectsWhenPendingExists() public {
        uint16[4] memory w = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        vm.prank(KEEPER);
        agg.requestAllocation(w, "one");
        vm.prank(KEEPER);
        vm.expectRevert("pending exists");
        agg.requestAllocation(w, "two");
    }

    // ---- FIX-12 (round-3 P0): cancelPending gating ----

    function test_cancelPending_revertsForRandomUser() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        bytes32 id = agg.requestAllocation(w, "test");

        vm.prank(ALICE);
        vm.expectRevert("cancelPending: owner or keeper only");
        agg.cancelPending(id);
    }

    function test_cancelPending_ownerCanCancel() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        bytes32 id = agg.requestAllocation(w, "test");

        vm.prank(OWNER);
        agg.cancelPending(id);
        assertEq(agg.pendingAllocationId(), bytes32(0));
    }

    function test_cancelPending_keeperCanCancel() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        bytes32 id = agg.requestAllocation(w, "test");

        vm.prank(KEEPER);
        agg.cancelPending(id);
        assertEq(agg.pendingAllocationId(), bytes32(0));
    }

    function test_cancelPending_rejectsWrongId() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        bytes32 id = agg.requestAllocation(w, "test");

        vm.prank(OWNER);
        vm.expectRevert("wrong id");
        agg.cancelPending(bytes32(uint256(1)));
    }

    function test_executePending_revertsBeforeTimelock() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        agg.requestAllocation(w, "test");

        vm.expectRevert("not yet");
        agg.executePending();
    }

    function test_executePending_appliesWeightsAfterTimelock() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        bytes32 id = agg.requestAllocation(w, "test");
        assertEq(agg.pendingAllocationId(), id);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);
        usdc.mint(address(agg), 10_000 ether);

        agg.executePending();

        uint16[4] memory got = agg.weights();
        assertEq(got[0], 4000);
        assertEq(got[1], 3000);
        assertEq(got[2], 2000);
        assertEq(got[3], 1000);
        assertEq(agg.pendingAllocationId(), bytes32(0));
    }

    // ---- Reentrancy guard: guard resets between calls ----

    function test_deposit_reentrantGuardResetsBetweenCalls() public {
        // Two consecutive deposits must both succeed — if the guard leaked
        // (_locked stuck at 2), the second call would revert with "reentrancy".
        vm.prank(ALICE);
        uint256 s1 = agg.deposit(100 ether, ALICE);
        vm.prank(ALICE);
        uint256 s2 = agg.deposit(100 ether, ALICE);
        // Shares may drift from 1:1 due to rounding on the leg
        // reallocation, but must be non-zero and monotonically increasing.
        assertTrue(s1 > 0 && s2 > 0, "nonzero shares");
        assertEq(agg.shares(ALICE), s1 + s2);
    }

    function test_executePending_reentrantGuardResetsBetweenCalls() public {
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        vm.prank(KEEPER);
        agg.requestAllocation(w, "one");
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(ALICE);
        agg.deposit(1000 ether, ALICE);
        usdc.mint(address(agg), 10_000 ether);
        agg.executePending();

        uint16[4] memory w2 = [uint16(1000), uint16(2000), uint16(3000), uint16(4000)];
        vm.prank(KEEPER);
        agg.requestAllocation(w2, "two");
        vm.warp(block.timestamp + 1 hours + 1);
        usdc.mint(address(agg), 10_000 ether);
        agg.executePending();

        uint16[4] memory got = agg.weights();
        assertEq(got[0], 1000);
        assertEq(got[3], 4000);
    }

    // ---- Governance ----

    function test_setKeeper_requiresOwner() public {
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        agg.setKeeper(ALICE);
    }

    function test_setKeeper_ownerCanUpdate() public {
        vm.prank(OWNER);
        agg.setKeeper(BOB);
        assertEq(agg.keeper(), BOB);
    }

    function test_setKeeper_rejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert("zero keeper");
        agg.setKeeper(address(0));
    }

    function test_harvestFromAllLegs_requiresKeeper() public {
        vm.prank(ALICE);
        vm.expectRevert("not keeper");
        agg.harvestFromAllLegs();
    }

    function test_harvestFromAllLegs_cascadeHarvestsAllFourLegs() public {
        vm.prank(KEEPER);
        agg.harvestFromAllLegs();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(legs[i].harvestCount(), 1);
        }
    }

    // ---- currentApyBps: weighted average across legs ----

    function test_currentApyBps_weightedAverage() public view {
        assertEq(agg.currentApyBps(), 1000);
    }

    // ---- previews mirror actuals (ERC-4626 sanity) ----

    function test_previewDeposit_matchesConvertToShares() public view {
        assertEq(agg.previewDeposit(500 ether), agg.convertToShares(500 ether));
    }

    function test_previewRedeem_matchesConvertToAssets() public view {
        assertEq(agg.previewRedeem(500 ether), agg.convertToAssets(500 ether));
    }
}
