// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/legs/KHYPELeg.sol";
import "../src/legs/SpotStakingLeg.sol";
import "../src/legs/PerpFundingLeg.sol";
import "../src/legs/BasisHedgeLeg.sol";
import "../src/interfaces/IERC20.sol";
import "../src/interfaces/IERC20Router.sol";
import "../src/interfaces/IStakingPool.sol";
import "../src/interfaces/IPriceOracle.sol";

/// Round-4 leg tests: cover the KI-3 (BasisHedgeLeg.allocateTo dust
/// guard) and KI-4 (setFixedApyBps refreshes latestApyBps) fixes.
contract LegsTest is Test {
    address constant OWNER  = address(0x1111);
    address constant ALICE  = address(0x2222);
    address constant TOKEN  = address(0xAAA1);   // dummy HYPE
    address constant POOL   = address(0xBB11);
    address constant WRITER = address(0xCC22);
    address constant TOA    = address(0xDD33);
    address constant FUND   = address(0xEE44);

    function setUp() public {
        // All tests run as OWNER (the deployer).
        vm.prank(OWNER);
    }

    function _deployKHYPE() internal returns (KHYPELeg) {
        // All optional integrations wired to non-zero addresses so the
        // leg's `address(x) == address(0)` checks are false and we
        // exercise the production paths.
        return new KHYPELeg(TOKEN, TOKEN, TOKEN, POOL, address(0), 1000);
    }

    function _deploySpot() internal returns (SpotStakingLeg) {
        return new SpotStakingLeg(TOKEN, TOKEN, TOKEN, POOL, address(0), 1000);
    }

    function _deployPerp() internal returns (PerpFundingLeg) {
        return new PerpFundingLeg(
            TOKEN, TOKEN, TOKEN, WRITER, TOA, address(0), FUND, TOKEN, 1000
        );
    }

    function _deployBasis() internal returns (BasisHedgeLeg) {
        return new BasisHedgeLeg(
            TOKEN, TOKEN, TOKEN, WRITER, TOA, address(0), TOKEN, 1000
        );
    }

    // ---- KI-4 (Round-4 fix): setFixedApyBps refreshes latestApyBps ----
    //
    // Each leg's expectedApy() reads `latestApyBps` when its oracle/funding
    // source is unwired (zero address). Before the fix, setFixedApyBps only
    // wrote `fixedApyBps`, so the cached `latestApyBps` stayed stale until
    // the next harvest/allocateTo. After the fix, expectedApy() reflects
    // the new value immediately when the oracle is unwired.

    function test_KI4_KHYPELeg_setFixedApyBps_refreshesExpectedApy() public {
        KHYPELeg leg = _deployKHYPE();
        assertEq(leg.expectedApy(), 1000, "initial fallback");

        vm.prank(OWNER);
        leg.setFixedApyBps(2000);

        // expectedApy must reflect the new value immediately (oracle
        // is unwired, so the fallback is authoritative).
        assertEq(leg.expectedApy(), 2000, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_SpotStakingLeg_setFixedApyBps_refreshesExpectedApy() public {
        SpotStakingLeg leg = _deploySpot();
        assertEq(leg.expectedApy(), 1000);
        vm.prank(OWNER);
        leg.setFixedApyBps(2500);
        assertEq(leg.expectedApy(), 2500, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_BasisHedgeLeg_setFixedApyBps_refreshesExpectedApy() public {
        BasisHedgeLeg leg = _deployBasis();
        assertEq(leg.expectedApy(), 1000);
        vm.prank(OWNER);
        leg.setFixedApyBps(1500);
        assertEq(leg.expectedApy(), 1500, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_PerpFundingLeg_setFixedApyBps_refreshesExpectedApy() public {
        PerpFundingLeg leg = _deployPerp();
        assertEq(leg.expectedApy(), 1000);
        vm.prank(OWNER);
        leg.setFixedApyBps(3000);
        assertEq(leg.expectedApy(), 3000, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_onlyOwner_canSetFixedApyBps() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.setFixedApyBps(500);
    }

    // ---- KI-3 (Round-4 fix): BasisHedgeLeg.allocateTo dust guard ----
    //
    // Before the fix, `allocateTo(1)` made spotPortion = 0, the
    // `if (spotPortion == 0) spotPortion = amount;` guard promoted it to
    // 1, and the perp side ended at 0 — the leg recorded 1 USDC of
    // allocation against a single-sided position. The fix rejects
    // amount < 2 with "dust".

    function test_KI3_BasisHedgeLeg_allocateTo_rejectsDust() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(OWNER);
        // Explicit bytes cast: 4-char literal "dust" is ambiguous
        // against Vm.expectRevert(bytes4), so we force the bytes overload.
        vm.expectRevert(bytes("dust"));
        leg.allocateTo(1);
    }

    function test_KI3_BasisHedgeLeg_allocateTo_zeroStillRejected() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(OWNER);
        // amount = 0 still trips the original "zero" guard, not "dust".
        vm.expectRevert(bytes("zero"));
        leg.allocateTo(0);
    }

    // ---- Regression: allocateTo non-owner reverts on all 4 legs ----

    function test_allocateTo_requiresOwner_KHYPE() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    function test_allocateTo_requiresOwner_Spot() public {
        SpotStakingLeg leg = _deploySpot();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    function test_allocateTo_requiresOwner_Perp() public {
        PerpFundingLeg leg = _deployPerp();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    function test_allocateTo_requiresOwner_Basis() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    // ---- Regression: name() returns the expected leg identifier ----

    function test_name_KHYPE() public {
        KHYPELeg leg = _deployKHYPE();
        assertEq(leg.name(), "KHYPELeg");
    }

    function test_name_Spot() public {
        SpotStakingLeg leg = _deploySpot();
        assertEq(leg.name(), "SpotStakingLeg");
    }

    function test_name_Perp() public {
        PerpFundingLeg leg = _deployPerp();
        assertEq(leg.name(), "PerpFundingLeg");
    }

    function test_name_Basis() public {
        BasisHedgeLeg leg = _deployBasis();
        assertEq(leg.name(), "BasisHedgeLeg");
    }

    // ---- Gap doc §2.4: reduceFrom guards on all 4 legs ----
    //
    // Each leg's reduceFrom must revert (not silently accept) when
    // called with no underlying allocation. The aggregator calls
    // reduceFrom inside executePending during rebalances; if a leg
    // ever gets into a state where its internal position is zero but
    // it claims a positive allocation, the guard must trip rather
    // than silently minting USDC out of nowhere. The revert message
    // is leg-specific but the property being pinned — "guard fires
    // when there's no position to reduce" — is uniform.

    function test_reduceFrom_KHYPE_zeroAllocationReverts() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(OWNER);
        vm.expectRevert(bytes("bad amount"));
        leg.reduceFrom(1);
    }

    function test_reduceFrom_Spot_zeroAllocationReverts() public {
        SpotStakingLeg leg = _deploySpot();
        vm.prank(OWNER);
        vm.expectRevert(bytes("bad amount"));
        leg.reduceFrom(1);
    }

    function test_reduceFrom_Perp_zeroAllocationReverts() public {
        PerpFundingLeg leg = _deployPerp();
        vm.prank(OWNER);
        vm.expectRevert(bytes("overreduce"));
        leg.reduceFrom(1);
    }

    function test_reduceFrom_Basis_zeroAllocationReverts() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(OWNER);
        vm.expectRevert(bytes("overreduce"));
        leg.reduceFrom(1);
    }

    // ---- Gap doc §2.4: reduceFrom requires owner on all 4 legs ----

    function test_reduceFrom_requiresOwner_KHYPE() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.reduceFrom(100);
    }

    function test_reduceFrom_requiresOwner_Spot() public {
        SpotStakingLeg leg = _deploySpot();
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.reduceFrom(100);
    }

    function test_reduceFrom_requiresOwner_Perp() public {
        PerpFundingLeg leg = _deployPerp();
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.reduceFrom(100);
    }

    function test_reduceFrom_requiresOwner_Basis() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.reduceFrom(100);
    }

    // ---- Gap doc §2.4: reduceFrom zero-amount revert ----

    function test_reduceFrom_KHYPE_zeroAmountReverts() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(OWNER);
        vm.expectRevert(bytes("bad amount"));
        leg.reduceFrom(0);
    }

    function test_reduceFrom_Spot_zeroAmountReverts() public {
        SpotStakingLeg leg = _deploySpot();
        vm.prank(OWNER);
        vm.expectRevert(bytes("bad amount"));
        leg.reduceFrom(0);
    }

    function test_reduceFrom_Perp_zeroAmountReverts() public {
        PerpFundingLeg leg = _deployPerp();
        vm.prank(OWNER);
        vm.expectRevert(bytes("zero"));
        leg.reduceFrom(0);
    }

    function test_reduceFrom_Basis_zeroAmountReverts() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(OWNER);
        vm.expectRevert(bytes("zero"));
        leg.reduceFrom(0);
    }
}

// ==================================================================
// KI-1 (DESIGN_KI1_UNIT_RECONCILE.md, Option A -- convert once at
// the boundary). Both stake legs must reconcile USDC <-> HYPE
// explicitly on every mutation; khypeBalance is tracked in HYPE
// units (18 dec), and pool.unstake must receive a stake-token
// amount derived via the live pool.exchangeRate(), never a raw
// USDC amount.
// ==================================================================

// ---- Mocks ----

contract MockUSDC is IERC20Minimal {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public totalSupply;
    function mint(address to, uint256 v) external { balanceOf[to] += v; totalSupply += v; }
    function approve(address to, uint256 v) external override returns (bool) {
        allowance[msg.sender][to] = v; return true;
    }
    function transfer(address to, uint256 v) external override returns (bool) {
        require(balanceOf[msg.sender] >= v, "bal");
        balanceOf[msg.sender] -= v; balanceOf[to] += v; return true;
    }
    function transferFrom(address from, address to, uint256 v) external override returns (bool) {
        require(balanceOf[from] >= v, "bal");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= v, "allow");
            allowance[from][msg.sender] = allowed - v;
        }
        balanceOf[from] -= v; balanceOf[to] += v; return true;
    }
}

contract MockHYPE is MockUSDC {}

contract MockPriceOracle is IPriceOracle {
    uint256 public hypePriceUsdc;
    uint256 public hypeApyBps = 1000;
    constructor(uint256 _p) { hypePriceUsdc = _p; }
    function setPrice(uint256 _p) external { hypePriceUsdc = _p; }
    function priceOf(string calldata t) external view override returns (uint256) {
        return keccak256(abi.encodePacked(t)) ==
                   keccak256(abi.encodePacked("HYPE"))
                ? hypePriceUsdc : 1_000_000;
    }
    function getApy(string calldata) external view override returns (uint256) {
        return hypeApyBps;
    }
}

contract MockRouter is IERC20Router {
    MockUSDC public usdc;
    MockHYPE public hype;
    MockPriceOracle public oracle;
    constructor(MockUSDC _usdc, MockHYPE _hype, MockPriceOracle _oracle) {
        usdc = _usdc; hype = _hype; oracle = _oracle;
    }
    function swapExactUSDCForToken(address, uint256 amountIn) external override returns (uint256 outAmount) {
        uint256 p = oracle.hypePriceUsdc();
        require(p > 0, "no price");
        outAmount = (amountIn * 1_000_000_000_000_000_000) / p;
        require(hype.balanceOf(address(this)) >= outAmount, "no hype out");
        hype.transfer(msg.sender, outAmount);
    }
    function swapExactTokenForUSDC(address, uint256 hypeIn) external override returns (uint256 outAmount) {
        uint256 p = oracle.hypePriceUsdc();
        require(p > 0, "no price");
        outAmount = (hypeIn * p) / 1_000_000_000_000_000_000;
        require(hype.balanceOf(msg.sender) >= hypeIn, "no hype in");
        hype.transferFrom(msg.sender, address(this), hypeIn);
        usdc.mint(msg.sender, outAmount);
    }
    function getAmountOut(address, address, uint256 amountIn) external view override returns (uint256) {
        return (amountIn * 1_000_000_000_000_000_000) / oracle.hypePriceUsdc();
    }
}

contract MockStakingPool is IStakingPool {
    uint256 public constant RATE_18 = 1_000_000_000_000_000_000;
    mapping(address => uint256) public staked;
    MockHYPE public hype;
    constructor(MockHYPE _hype) { hype = _hype; }
    function exchangeRate() external view override returns (uint256) { return RATE_18; }
    function unbondingPeriod() external view override returns (uint256) { return 0; }
    function stake(address, uint256 amount) external override {
        require(hype.balanceOf(msg.sender) >= amount, "no hype");
        hype.transferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        emit Staked(msg.sender, amount);
    }
    function unstake(address stakeToken, uint256 amount) external override {
        require(staked[stakeToken] >= amount, "no stake tokens");
        staked[stakeToken] -= amount;
        emit Unstaked(stakeToken, amount, 0);
    }
    function creditUnbonded(address stakeToken, uint256 amount, address to) external override returns (uint256) {
        require(hype.balanceOf(address(this)) >= amount, "no hype in pool");
        hype.transfer(to, amount);
        emit Unbonded(to, amount);
        return amount;
    }
    function balanceOf(address stakeToken, address account) external view override returns (uint256) {
        return staked[account];
    }
}

contract KI1ReconcileTest is Test {
    address constant OWNER = address(0x1111);

    MockUSDC usdc;
    MockHYPE hype;
    MockPriceOracle oracle;
    MockRouter router;
    MockStakingPool pool;

    uint256 constant PRICE_200 = 2_000_000;
    uint256 constant PRICE_250 = 2_500_000;
    uint256 constant USD_1000 = 1_000_000 * 1_000;
    uint256 constant USD_500 = 500_000 * 1_000;

    function setUp() public {
        usdc   = new MockUSDC();
        hype   = new MockHYPE();
        oracle = new MockPriceOracle(PRICE_200);
        router = new MockRouter(usdc, hype, oracle);
        pool   = new MockStakingPool(hype);
        hype.mint(address(router), 1_000_000 * 1_000_000_000_000_000_000);
        usdc.mint(OWNER, 1_000_000 * 1_000 * 1_000);
    }

    function _deployKHYPE() internal returns (KHYPELeg) {
        vm.startPrank(OWNER);
        KHYPELeg leg = new KHYPELeg(address(usdc), address(hype),
                                     address(router), address(pool),
                                     address(oracle), 1000);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }

    function _deploySpot() internal returns (SpotStakingLeg) {
        vm.startPrank(OWNER);
        SpotStakingLeg leg = new SpotStakingLeg(address(usdc), address(hype),
                                                 address(router), address(pool),
                                                 address(oracle), 1000);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }

    function test_KI1_KHYPELeg_allocate_atFixedPrice() public {
        KHYPELeg leg = _deployKHYPE();
        vm.startPrank(OWNER);
        uint256 returned = leg.allocateTo(USD_1000);
        vm.stopPrank();
        assertEq(returned, USD_1000, "allocateTo returned");
        assertEq(leg.khypeBalance(), 500 * 1_000_000_000_000_000_000, "khypeBalance in HYPE units");
        assertEq(leg.allocatedUsd(), USD_1000, "allocatedUsd ledger");
        assertEq(leg.currentValue(), USD_1000, "currentValue at fixed price");
    }

    function test_KI1_KHYPELeg_reduce_from_unstakes_correct_token_amount() public {
        KHYPELeg leg = _deployKHYPE();
        vm.startPrank(OWNER);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        uint256 beforeUnstaked = pool.staked(address(leg));
        assertEq(beforeUnstaked, 500 * 1_000_000_000_000_000_000, "pool staked after allocate");
        vm.startPrank(OWNER);
        uint256 returned = leg.reduceFrom(USD_500);
        vm.stopPrank();
        assertEq(beforeUnstaked - pool.staked(address(leg)), 250 * 1_000_000_000_000_000_000,
                 "pool unstaked the right stake-token amount");
        assertEq(returned, USD_500, "USDC returned to owner");
        assertEq(leg.allocatedUsd(), USD_500, "allocatedUsd dropped by reduce");
        assertEq(leg.khypeBalance(), 250 * 1_000_000_000_000_000_000, "khypeBalance in HYPE units");
    }

    function test_KI1_KHYPELeg_currentValue_re_rates_after_oracle_repricing() public {
        KHYPELeg leg = _deployKHYPE();
        vm.startPrank(OWNER);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        assertEq(leg.khypeBalance(), 500 * 1_000_000_000_000_000_000, "khypeBalance after allocate");
        assertEq(leg.currentValue(), USD_1000, "currentValue at $2.00");
        oracle.setPrice(PRICE_250);
        assertEq(leg.khypeBalance(), 500 * 1_000_000_000_000_000_000, "khypeBalance unchanged on price drift");
        assertEq(leg.currentValue(), 1_250_000_000, "currentValue at $2.50 = 500 * 2.50");
        vm.startPrank(OWNER);
        uint256 returned = leg.reduceFrom(USD_500);
        vm.stopPrank();
        assertEq(returned, USD_500, "returned at new price");
        assertEq(leg.khypeBalance(), 300 * 1_000_000_000_000_000_000, "residual khypeBalance in HYPE units");
        assertEq(leg.currentValue(), 750_000_000, "currentValue = 300 HYPE @ $2.50");
    }

    function test_KI1_KHYPELeg_reduce_no_USDC_subtracted_from_HYPE_counter() public {
        KHYPELeg leg = _deployKHYPE();
        vm.startPrank(OWNER);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        assertEq(leg.khypeBalance(), 500 * 1_000_000_000_000_000_000);
        vm.startPrank(OWNER);
        leg.reduceFrom(USD_500);
        vm.stopPrank();
        assertEq(leg.khypeBalance(), 250 * 1_000_000_000_000_000_000,
                 "khypeBalance dropped by the HYPE equivalent, not the raw USDC");
    }

    function test_KI1_SpotStakingLeg_allocate_atFixedPrice() public {
        SpotStakingLeg leg = _deploySpot();
        vm.startPrank(OWNER);
        uint256 returned = leg.allocateTo(USD_1000);
        vm.stopPrank();
        assertEq(returned, USD_1000);
        assertEq(leg.rewardHypeBalance(), 500 * 1_000_000_000_000_000_000, "rewardHypeBalance in HYPE units");
        assertEq(leg.allocatedUsd(), USD_1000);
        assertEq(leg.currentValue(), USD_1000);
    }

    function test_KI1_SpotStakingLeg_reduce_unstakes_correct_amount() public {
        SpotStakingLeg leg = _deploySpot();
        vm.startPrank(OWNER);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        uint256 before = pool.staked(address(leg));
        assertEq(before, 500 * 1_000_000_000_000_000_000);
        vm.startPrank(OWNER);
        uint256 returned = leg.reduceFrom(USD_500);
        vm.stopPrank();
        assertEq(before - pool.staked(address(leg)), 250 * 1_000_000_000_000_000_000,
                 "unstaked the right stake-token amount");
        assertEq(returned, USD_500);
        assertEq(leg.rewardHypeBalance(), 250 * 1_000_000_000_000_000_000, "rewardHypeBalance in HYPE units");
        assertEq(leg.allocatedUsd(), USD_500);
    }

    function test_KI1_SpotStakingLeg_currentValue_re_rates_on_oracle_drift() public {
        SpotStakingLeg leg = _deploySpot();
        vm.startPrank(OWNER);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        assertEq(leg.rewardHypeBalance(), 500 * 1_000_000_000_000_000_000);
        assertEq(leg.currentValue(), USD_1000);
        oracle.setPrice(PRICE_250);
        assertEq(leg.rewardHypeBalance(), 500 * 1_000_000_000_000_000_000);
        assertEq(leg.currentValue(), 1_250_000_000, "currentValue at $2.50");
    }
}
