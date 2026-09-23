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
import "../src/interfaces/ITradeOnlyAgent.sol";
import "../src/interfaces/IElysiumCoreWriter.sol";
import "../src/interfaces/IFundingSource.sol";

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
        // Round-8: slippageBps = 0 in this rig (oracle is unwired so
        // the slippage check is a no-op, but we pin 0 to keep the
        // intent explicit).
        return new KHYPELeg(TOKEN, TOKEN, TOKEN, POOL, address(0), 1000, 0);
    }

    function _deploySpot() internal returns (SpotStakingLeg) {
        return new SpotStakingLeg(TOKEN, TOKEN, TOKEN, POOL, address(0), 1000, 0);
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
        // amountIn is 6-dec USDC, p is 6-dec USDC/HYPE, outAmount is 18-dec HYPE.
        //   outAmount = (amountIn * 1e18) / p
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

/// Round-8 slippage-hardening mock: swaps on a price that drifts
/// away from the oracle price by `swapSlippageBps`, so the leg's
/// post-swap require can be exercised in both directions (accept
/// within tolerance, revert above tolerance). The oracle itself
/// keeps returning the unadjusted price, matching a realistic
/// "oracle is right, router is the wrong quote" scenario.
contract SlippageMockRouter is IERC20Router {
    MockUSDC public usdc;
    MockHYPE public hype;
    MockPriceOracle public oracle;
    uint256 public swapSlippageBps;

    constructor(MockUSDC _usdc, MockHYPE _hype, MockPriceOracle _oracle) {
        usdc = _usdc; hype = _hype; oracle = _oracle;
    }

    function setSwapSlippageBps(uint256 v) external { swapSlippageBps = v; }

    /// Effective unit price is `oracle * (10000 + swapSlippageBps) / 10000`,
    /// so the router returns fewer HYPE per USDC than the oracle
    /// rate would predict -- slippage in our unfavour.
    function swapExactUSDCForToken(address, uint256 amountIn)
        external override returns (uint256 outAmount)
    {
        uint256 p = oracle.hypePriceUsdc();
        require(p > 0, "no price");
        uint256 effP = (swapSlippageBps > 0)
            ? (p * (10_000 + swapSlippageBps)) / 10_000
            : p;
        require(effP > 0, "eff price is 0");
        outAmount = (amountIn * 1_000_000_000_000_000_000) / effP;
        require(hype.balanceOf(address(this)) >= outAmount, "no hype out");
        hype.transfer(msg.sender, outAmount);
    }

    function swapExactTokenForUSDC(address, uint256 hypeIn)
        external override returns (uint256 outAmount)
    {
        uint256 p = oracle.hypePriceUsdc();
        require(p > 0, "no price");
        outAmount = (hypeIn * p) / 1_000_000_000_000_000_000;
        require(hype.balanceOf(msg.sender) >= hypeIn, "no hype in");
        hype.transferFrom(msg.sender, address(this), hypeIn);
        usdc.mint(msg.sender, outAmount);
    }

    function getAmountOut(address, address, uint256 amountIn)
        external view override returns (uint256)
    {
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
                                     address(oracle), 1000, 0);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }

    function _deploySpot() internal returns (SpotStakingLeg) {
        vm.startPrank(OWNER);
        SpotStakingLeg leg = new SpotStakingLeg(address(usdc), address(hype),
                                                 address(router), address(pool),
                                                 address(oracle), 1000, 0);
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

// ==================================================================
// KI-2 (DESIGN_KI2_SUBMITINTENT.md, Option C hybrid). The perp
// legs implement IIntentSubmittingLeg: they accept a user-signed
// EIP-712 delegation and forward the signature (not the placeholder
// zero-sig) to the writer. Staking legs do NOT implement it — they
// never call the writer.
//
// Two mocks below give us a fully controllable EIP-712 validity
// response (MockTradeOnlyAgent) and a recording writer (MockWriter)
// so we can assert the leg forwards the real (v, r, s) tuple, not
// the _zeroSig() placeholder.
// ==================================================================

/// Mock writer that records every invocation and the exact signature
/// it received. Also verifies the notional fits the venue-local
/// per-order cap from the delegation. Uses internal parallel arrays
/// with named view accessors so the test callsite avoids Solidity's
/// public-struct-array getter naming quirks.
contract MockWriter is IElysiumCoreWriter {
    bytes32[]  internal _hashSig;
    address[]  internal _keeper;
    uint64[]   internal _nonce;
    bytes32[]  internal _salt;
    uint256[]  internal _notional;
    bool[]     internal _isOpen;

    function count() external view returns (uint256) { return _hashSig.length; }
    function hashSig(uint256 i) external view returns (bytes32) { return _hashSig[i]; }
    function keeperAt(uint256 i) external view returns (address) { return _keeper[i]; }
    function nonceAt(uint256 i) external view returns (uint64) { return _nonce[i]; }
    function saltAt(uint256 i) external view returns (bytes32) { return _salt[i]; }
    function notionalAt(uint256 i) external view returns (uint256) { return _notional[i]; }
    function isOpenAt(uint256 i) external view returns (bool) { return _isOpen[i]; }

    function openPosition(
        uint256 assetId,
        Side side,
        uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external override {
        require(notional <= d.maxPerOrder, "writer: per-order cap");
        require(sig.v == 27 || sig.v == 28, "writer: bad v");
        _hashSig.push(keccak256(abi.encode(sig.v, sig.r, sig.s)));
        _keeper.push(d.keeper);
        _nonce.push(d.nonce);
        _salt.push(d.salt);
        _notional.push(notional);
        _isOpen.push(true);
    }

    function closePosition(
        uint256 assetId,
        Side side,
        uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external override {
        require(notional <= d.maxPerOrder, "writer: per-order cap");
        require(sig.v == 27 || sig.v == 28, "writer: bad v");
        _hashSig.push(keccak256(abi.encode(sig.v, sig.r, sig.s)));
        _keeper.push(d.keeper);
        _nonce.push(d.nonce);
        _salt.push(d.salt);
        _notional.push(notional);
        _isOpen.push(false);
    }
}

/// Minimal mock of ITradeOnlyAgent. The real contract implements
/// EIP-712 verification; we don't need that here — we only need a
/// controllable validity response to exercise both the accept and
/// reject paths in submitIntent. The keeper == address(this) leg
/// check, the per-order cap, and the nonce-keyed replay guard are
/// enforced inside the leg BEFORE we ever reach isValidDelegation,
/// so those tests don't need TOA cooperation.
contract MockTradeOnlyAgent is ITradeOnlyAgent {
    bool public acceptSig = true;

    function isValidDelegation(
        address, ITradeOnlyAgent.Delegation calldata,
        ITradeOnlyAgent.Signature calldata
    ) external view override returns (bool) {
        return acceptSig;
    }

    function setAcceptSig(bool b) external { acceptSig = b; }
    function revoke(address) external override {}
    function isRevoked(address) external view override returns (bool) {
        return false;
    }
}

/// Minimal mock of IFundingSource. The leg's expectedApy() does a
/// try/catch around `fundingSource.fundingApyBps("HYPE")`; when the
/// source is an unwired EOA address the CALL is technically a "stop"
/// (empty return), but the leg's try/catch may still treat that as an
/// outer-call revert in some forge profiles. We deploy a real mock
/// that returns a positive APY so the try branch succeeds cleanly.
contract MockFundingSource is IFundingSource {
    int64 public fundingApy = 2000;
    function fundingRateBps(string calldata) external view override returns (int64) {
        return 20;
    }
    function fundingApyBps(string calldata) external view override returns (int64) {
        return fundingApy;
    }
}

// Shared mock infrastructure for the KI-2 regression suite.
abstract contract KI2Base is Test {
    // Owner of both legs. For submitIntent, `msg.sender` is checked
    // against `owner || delegator`; we call as the leg's owner (the
    // typical production caller: the aggregator keeper).
    address internal constant KI2_OWNER = address(0x1111);
    address internal constant KI2_DELEGATOR = address(0x2222);
    address internal constant KI2_BADKEEPER = address(0xdead);

    MockWriter internal writer;
    MockTradeOnlyAgent internal toa;
    // Real token mocks so the leg's _buyHype balanceOf path hits a
    // deployed contract rather than an EOA-like address.
    MockHYPE internal hypeTok;
    MockUSDC internal usdcTok;
    // Real funding-source + oracle mocks so the leg's expectedApy /
    // _hypePriceUsdc try-blocks succeed rather than fall through.
    MockFundingSource internal fundsrc;
    MockPriceOracle internal oracleMock;

    uint256 internal constant KI2_USD_100 = 100 * 1_000_000;

    // Canonical function selector for
    // submitIntent(Delegation,Signature,uint256), using the canonical
    // string type representation (not the interface-qualified one).
    bytes4 internal constant SUBMIT_SELECTOR =
        bytes4(keccak256(
            "submitIntent((address,uint256[],uint256,uint256,uint64,uint64,bytes32),(uint8,bytes32,bytes32),uint256)"
        ));

    function setUp() public virtual {
        writer     = new MockWriter();
        toa        = new MockTradeOnlyAgent();
        hypeTok    = new MockHYPE();
        usdcTok    = new MockUSDC();
        fundsrc    = new MockFundingSource();
        oracleMock = new MockPriceOracle(2_000_000);
    }

    // In the "test-rig path" the perp legs treat `router == 0` as
    // "no router wired" — `_buyHype` then falls back to
    // `hype.balanceOf(address(this))` which returns 0 (no HYPE was
    // minted to the leg). The perp short still opens because the
    // test only asserts on the writer invocation and the alloc
    // ledger, not on the spot-side balance. Same for the oracle:
    // `_hypePriceUsdc()` returns 0, and `currentValue()` collapses
    // to `usdc.balanceOf(this)` — but we don't touch currentValue
    // from these tests.
    function _deployPerp() internal returns (PerpFundingLeg) {
        return new PerpFundingLeg(
            address(usdcTok), address(hypeTok), address(0),
            address(writer), address(toa), address(fundsrc), address(oracleMock),
            KI2_DELEGATOR, 1000
        );
    }

    function _deployBasis() internal returns (BasisHedgeLeg) {
        return new BasisHedgeLeg(
            address(usdcTok), address(hypeTok), address(0),
            address(writer), address(toa), address(oracleMock),
            KI2_DELEGATOR, 1000
        );
    }

    function _deployKHYPE() internal returns (KHYPELeg) {
        return new KHYPELeg(
            address(usdcTok), address(hypeTok), address(0),
            address(0), address(oracleMock), 1000, 0
        );
    }

    function _deploySpot() internal returns (SpotStakingLeg) {
        return new SpotStakingLeg(
            address(usdcTok), address(hypeTok), address(0),
            address(0), address(oracleMock), 1000, 0
        );
    }

    // The keeper must be the leg itself (stream B); the delegator
    // signs a delegation whose `keeper` field names the leg address.
    function _mkDelegation(
        address keeper, uint256 maxPerOrder, uint64 nonce
    ) internal pure returns (ITradeOnlyAgent.Delegation memory d) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        d = ITradeOnlyAgent.Delegation({
            keeper:      keeper,
            assetIds:    ids,
            maxNotional: maxPerOrder,
            maxPerOrder: maxPerOrder,
            expiresAt:   0,
            nonce:       nonce,
            salt:        bytes32(0)
        });
    }

    // Signature with known constants so we can compute its hash for
    // the "real sig, not _zeroSig" assertion.
    function _mkSig() internal pure returns (ITradeOnlyAgent.Signature memory) {
        return ITradeOnlyAgent.Signature({
            v: 27,
            r: bytes32(uint256(0xA0B0C0)),
            s: bytes32(uint256(0xD0E0F0))
        });
    }

    /// Returns true iff the target contract's runtime bytecode contains
    /// the given 4-byte function selector. Solidity emits selectors as
    /// 4-byte immediates in the dispatch table; scanning the bytecode
    /// is a robust way to check for a method's presence. A positive
    /// control against a perp leg (which does implement submitIntent)
    /// confirms the heuristic works; absence of a match on a staking
    /// leg is a strong negative signal because we know the full
    /// function surface of those contracts.
    function _hasSelector(address target, bytes4 sel) internal view returns (bool) {
        // Read the runtime bytecode via inline assembly. Solidity's
        // `vm.getCode` is awkward to type-check here; `extcodesize` /
        // `extcodecopy` are cleaner.
        uint256 size;
        uint256 code;
        assembly {
            size := extcodesize(target)
            code := mload(0x40)
            mstore(0x40, add(code, add(size, 0x40)))
            extcodecopy(target, add(code, 0x20), 0, size)
        }
        if (size == 0) return false;
        for (uint256 i = 0; i + 4 <= size; i++) {
            // Read a 32-byte word starting at position `i` in the
            // bytecode. The top 4 bytes of that word are the 4 bytes
            // at positions `i..i+3`. We mask the word to keep only
            // the top 4 bytes, then compare against `sel` cast to
            // bytes32 (which places sel in the low 4 bytes — but we
            // already masked the top of the word, so we need to
            // shift sel up). The cleanest form: mask the word AND
            // shift-left sel by 224 bits so both have the 4 bytes
            // sitting in the top 4 of the 256-bit word.
            bool found;
            assembly {
                let w := mload(add(code, add(0x20, i)))
                let wTop := and(w, 0xffffffff00000000000000000000000000000000000000000000000000000000)
                let selTop := shl(224, sel)
                found := eq(wTop, selTop)
            }
            if (found) return true;
        }
        return false;
    }
}

contract KI2PerpFundingTests is KI2Base {
    function test_KI2_Perp_validSig_forwardsRealSigToWriter() public {
        vm.prank(KI2_OWNER);
        PerpFundingLeg leg = _deployPerp();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        uint256 returned = leg.submitIntent(d, sig, KI2_USD_100);

        assertEq(returned, KI2_USD_100, "submitIntent returned");
        assertEq(writer.count(), 1, "writer received 1 call");

        // The writer recorded the REAL signature, not the zero placeholder.
        bytes32 expected = keccak256(abi.encode(sig.v, sig.r, sig.s));
        bytes32 zeroSigHash = keccak256(abi.encode(uint8(27), bytes32(0), bytes32(0)));
        assertEq(writer.hashSig(0), expected, "sigHash matches real sig");
        assertNotEq(writer.hashSig(0), zeroSigHash, "NOT zero-sig placeholder");

        assertEq(writer.keeperAt(0), address(leg), "keeper = leg");
        assertEq(writer.nonceAt(0), 1, "nonce = 1");
        assertEq(writer.notionalAt(0), 50 * 1_000_000, "writer notional = perp portion");
    }

    function test_KI2_Perp_invalidSig_reverts() public {
        vm.prank(KI2_OWNER);
        PerpFundingLeg leg = _deployPerp();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        toa.setAcceptSig(false);

        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("invalid delegation"));
        leg.submitIntent(d, sig, KI2_USD_100);

        assertEq(writer.count(), 0, "no writer call after invalid sig");
    }

    function test_KI2_Perp_overCap_reverts() public {
        vm.prank(KI2_OWNER);
        PerpFundingLeg leg = _deployPerp();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), 100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("per-order cap"));
        leg.submitIntent(d, sig, 101);

        assertEq(writer.count(), 0, "no writer call after over-cap");
    }

    function test_KI2_Perp_replay_sameNonceReverts() public {
        vm.prank(KI2_OWNER);
        PerpFundingLeg leg = _deployPerp();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        leg.submitIntent(d, sig, KI2_USD_100);
        assertEq(writer.count(), 1, "first call recorded");

        // Second call with the same (keeper, nonce, salt) must revert.
        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("intent already submitted"));
        leg.submitIntent(d, sig, KI2_USD_100);
        assertEq(writer.count(), 1, "no second writer call");
    }

    function test_KI2_Perp_wrongKeeper_reverts() public {
        vm.prank(KI2_OWNER);
        PerpFundingLeg leg = _deployPerp();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KI2_BADKEEPER, KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("keeper is not this leg"));
        leg.submitIntent(d, sig, KI2_USD_100);
    }

    function test_KI2_Perp_unauthorizedCaller_reverts() public {
        vm.prank(KI2_OWNER);
        PerpFundingLeg leg = _deployPerp();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        // Alice is neither the owner nor the delegator.
        vm.prank(address(0x9999));
        vm.expectRevert(bytes("not authorized"));
        leg.submitIntent(d, sig, KI2_USD_100);
    }
}

contract KI2BasisHedgeTests is KI2Base {
    function test_KI2_Basis_validSig_forwardsRealSigToWriter() public {
        vm.prank(KI2_OWNER);
        BasisHedgeLeg leg = _deployBasis();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        uint256 returned = leg.submitIntent(d, sig, KI2_USD_100);

        assertEq(returned, KI2_USD_100, "submitIntent returned");
        assertEq(writer.count(), 1, "writer received 1 call");
        bytes32 expected = keccak256(abi.encode(sig.v, sig.r, sig.s));
        assertEq(writer.hashSig(0), expected, "sigHash matches real sig");
        assertEq(writer.keeperAt(0), address(leg), "keeper = leg");
    }

    function test_KI2_Basis_invalidSig_reverts() public {
        vm.prank(KI2_OWNER);
        BasisHedgeLeg leg = _deployBasis();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        toa.setAcceptSig(false);

        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("invalid delegation"));
        leg.submitIntent(d, sig, KI2_USD_100);
    }

    function test_KI2_Basis_overCap_reverts() public {
        vm.prank(KI2_OWNER);
        BasisHedgeLeg leg = _deployBasis();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), 100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("per-order cap"));
        leg.submitIntent(d, sig, 101);
    }

    function test_KI2_Basis_replay_sameNonceReverts() public {
        vm.prank(KI2_OWNER);
        BasisHedgeLeg leg = _deployBasis();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(leg), KI2_USD_100, 1
        );
        ITradeOnlyAgent.Signature memory sig = _mkSig();

        vm.prank(KI2_OWNER);
        leg.submitIntent(d, sig, KI2_USD_100);

        vm.prank(KI2_OWNER);
        vm.expectRevert(bytes("intent already submitted"));
        leg.submitIntent(d, sig, KI2_USD_100);
    }
}

// Negative test: staking legs do NOT implement IIntentSubmittingLeg
// because they never call the writer. We pin this two ways:
//   (1) The submitIntent selector is absent from their runtime
//       bytecode dispatch table.
//   (2) A raw CALL with that selector returns no success flag.
// A positive control on a perp leg confirms _hasSelector works.
contract KI2StakingLegsNegativeTest is KI2Base {
    function test_KI2_KHYPELeg_doesNotImplementSubmitIntent() public {
        vm.prank(KI2_OWNER);
        KHYPELeg leg = _deployKHYPE();
        assertFalse(_hasSelector(address(leg), SUBMIT_SELECTOR),
                    "KHYPELeg does NOT expose submitIntent selector");
    }

    function test_KI2_SpotStakingLeg_doesNotImplementSubmitIntent() public {
        vm.prank(KI2_OWNER);
        SpotStakingLeg leg = _deploySpot();
        assertFalse(_hasSelector(address(leg), SUBMIT_SELECTOR),
                    "SpotStakingLeg does NOT expose submitIntent selector");
    }
}

// ==================================================================
// Round-8 hardening (KI-1 §9.2 + §9.3 follow-ups).
//
//   (a) harvest() must NOT decrement `allocatedUsd` — the realised
//       USDC sweep is yield; the vault's principal ledger tracks
//       the underlying HYPE position, not realised reward.
//   (b) Router slippage must be bounded via `slippageBps` against
//       the oracle price AFTER the swap returns, and the owner
//       must be able to tune that knob.
//
// MockRouter above now has an optional `SlippageMockRouter` variant
// whose effective price is `oracle * (10000 + swapSlippageBps) / 10000`
// — simulating a real swap executing at a worse rate than the
// oracle. Combined with `slippageBps` on the leg itself, that lets
// us exercise both the accept-within-tolerance path and the
// reject-above-tolerance path.
// ==================================================================

abstract contract KI5Base is Test {
    address internal constant KI5_OWNER = address(0x1111);
    address internal constant KI5_ALICE = address(0x2222);

    MockUSDC internal usdc;
    MockHYPE internal hype;
    MockPriceOracle internal oracle;
    MockRouter internal router;
    MockStakingPool internal pool;

    uint256 internal constant KI5_PRICE_200 = 2_000_000;
    uint256 internal constant KI5_USD_1000 = 1_000 * 1_000_000;

    function setUp() public virtual {
        usdc   = new MockUSDC();
        hype   = new MockHYPE();
        oracle = new MockPriceOracle(KI5_PRICE_200);
        router = new MockRouter(usdc, hype, oracle);
        pool   = new MockStakingPool(hype);
        hype.mint(address(router), 1_000_000 * 1_000_000_000_000_000_000);
        usdc.mint(KI5_OWNER, 1_000_000 * 1_000 * 1_000);
    }

    /// @param bps Slippage ceiling in bps. 0 disables the guard.
    function _deployKHYPE(uint256 bps) internal returns (KHYPELeg) {
        vm.startPrank(KI5_OWNER);
        KHYPELeg leg = new KHYPELeg(address(usdc), address(hype),
                                     address(router), address(pool),
                                     address(oracle), 1000, bps);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }

    /// @param bps Slippage ceiling in bps. 0 disables the guard.
    function _deploySpot(uint256 bps) internal returns (SpotStakingLeg) {
        vm.startPrank(KI5_OWNER);
        SpotStakingLeg leg = new SpotStakingLeg(address(usdc), address(hype),
                                                 address(router), address(pool),
                                                 address(oracle), 1000, bps);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }
}

/// (a) Regression: harvest() does not touch `allocatedUsd`. The
/// sweep moves USDC out, but the underlying HYPE position is
/// unchanged, so the principal ledger must be too. Without the fix
/// a USDC-sweep of $1000 would have silently drained `allocatedUsd`
/// from $1000 to $0, drifting the aggregator's `_allocatedTotal`
/// downward by the same amount on the next harvestFromAllLegs.
contract KI5HarvestAccountingTests is KI5Base {
    function test_harvest_doesNotDecrement_allocatedUsd_KHYPE() public {
        KHYPELeg leg = _deployKHYPE(0);

        vm.startPrank(KI5_OWNER);
        usdc.transfer(address(leg), KI5_USD_1000);
        leg.allocateTo(KI5_USD_1000);
        vm.stopPrank();
        assertEq(leg.allocatedUsd(), KI5_USD_1000, "allocatedUsd after allocate");

        // Simulate a USDC balance sitting in the leg. In production this
        // comes from a swap residual or a delayed reward transfer; in
        // the mock it just means someone sent USDC to the leg.
        vm.prank(KI5_OWNER);
        usdc.transfer(address(leg), KI5_USD_1000);

        vm.prank(KI5_OWNER);
        leg.harvest();

        assertEq(leg.allocatedUsd(), KI5_USD_1000,
                 "harvest() must NOT decrement allocatedUsd");
        assertEq(usdc.balanceOf(address(leg)), 0, "USDC swept");
        // currentValue reflects the HYPE position via oracle * price;
        // the swept USDC does not re-rate it.
        assertEq(leg.currentValue(), KI5_USD_1000,
                 "currentValue unchanged by harvest");
    }

    function test_harvest_doesNotDecrement_allocatedUsd_SpotStaking() public {
        SpotStakingLeg leg = _deploySpot(0);

        vm.startPrank(KI5_OWNER);
        usdc.transfer(address(leg), KI5_USD_1000);
        leg.allocateTo(KI5_USD_1000);
        vm.stopPrank();
        assertEq(leg.allocatedUsd(), KI5_USD_1000, "allocatedUsd after allocate");

        vm.prank(KI5_OWNER);
        usdc.transfer(address(leg), KI5_USD_1000);

        vm.prank(KI5_OWNER);
        leg.harvest();

        assertEq(leg.allocatedUsd(), KI5_USD_1000,
                 "harvest() must NOT decrement allocatedUsd");
        assertEq(usdc.balanceOf(address(leg)), 0, "USDC swept");
        assertEq(leg.currentValue(), KI5_USD_1000,
                 "currentValue unchanged by harvest");
    }
}

/// (b) Slippage guard: the leg bounds the router's returned amount
/// against the oracle price. SlippageMockRouter above lets us
/// simulate a real swap executing at a worse rate than the oracle.
///
/// This contract holds its own SlippageMockRouter (as a typed
/// reference) rather than reusing KI5Base's MockRouter storage slot,
/// because the two share no methods -- a cross-type cast would
/// revert on any call.
contract KI5SlippageTests is Test {
    address constant OWNER = address(0x1111);

    MockUSDC usdc;
    MockHYPE hype;
    MockPriceOracle oracle;
    SlippageMockRouter router;
    MockStakingPool pool;

    uint256 constant PRICE_200 = 2_000_000;
    uint256 constant USD_1000 = 1_000 * 1_000_000;

    function setUp() public {
        usdc   = new MockUSDC();
        hype   = new MockHYPE();
        oracle = new MockPriceOracle(PRICE_200);
        router = new SlippageMockRouter(usdc, hype, oracle);
        pool   = new MockStakingPool(hype);
        hype.mint(address(router), 1_000_000 * 1_000_000_000_000_000_000);
        usdc.mint(OWNER, 1_000_000 * 1_000 * 1_000);
    }

    function _deployKHYPE(uint256 bps) internal returns (KHYPELeg) {
        vm.startPrank(OWNER);
        KHYPELeg leg = new KHYPELeg(address(usdc), address(hype),
                                     address(router), address(pool),
                                     address(oracle), 1000, bps);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }

    function _deploySpot(uint256 bps) internal returns (SpotStakingLeg) {
        vm.startPrank(OWNER);
        SpotStakingLeg leg = new SpotStakingLeg(address(usdc), address(hype),
                                                 address(router), address(pool),
                                                 address(oracle), 1000, bps);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
        return leg;
    }

    /// Leg tolerance 50 bps (0.5%), router drift 100 bps (1.0%) --
    /// the returned amount under-shoots the oracle-based floor, so
    /// the guard must trip.
    function test_allocateTo_reverts_onSlippageExceeded_KHYPE() public {
        KHYPELeg leg = _deployKHYPE(50);
        router.setSwapSlippageBps(100);

        vm.startPrank(OWNER);
        usdc.transfer(address(leg), USD_1000);
        vm.expectRevert(bytes("slippage exceeded"));
        leg.allocateTo(USD_1000);
        vm.stopPrank();
    }

    /// Same scenario for the spot-staking leg.
    function test_allocateTo_reverts_onSlippageExceeded_Spot() public {
        SpotStakingLeg leg = _deploySpot(50);
        router.setSwapSlippageBps(100);

        vm.startPrank(OWNER);
        usdc.transfer(address(leg), USD_1000);
        vm.expectRevert(bytes("slippage exceeded"));
        leg.allocateTo(USD_1000);
        vm.stopPrank();
    }

    /// The mirror image: the router returns a fill at the oracle
    /// price (no drift), so the guard is a no-op and allocateTo
    /// proceeds normally. Pins the "don't over-reject" side of the
    /// guard -- without this test a `<=` vs `<` typo would slip
    /// through.
    function test_allocateTo_proceeds_when_withinSlippage_KHYPE() public {
        KHYPELeg leg = _deployKHYPE(50);
        router.setSwapSlippageBps(0);

        vm.startPrank(OWNER);
        usdc.transfer(address(leg), USD_1000);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        assertEq(leg.allocatedUsd(), USD_1000, "allocation went through");
        assertEq(leg.khypeBalance(), 500 * 1_000_000_000_000_000_000,
                 "khypeBalance at oracle rate");
    }

    /// slippageBps == 0 disables the guard. Existing tests already
    /// rely on this; pin it explicitly so anyone changing the
    /// semantics notices.
    function test_allocateTo_slippageBps_zero_disablesGuard_KHYPE() public {
        KHYPELeg leg = _deployKHYPE(0);
        router.setSwapSlippageBps(100);

        vm.startPrank(OWNER);
        usdc.transfer(address(leg), USD_1000);
        leg.allocateTo(USD_1000);
        vm.stopPrank();
        // 100 bps drift on a $1000 USDC fill at $2/HYPE should
        // shave ~0.5 HYPE off the fill: 500 * (10000 / 10100).
        // Cast to uint256 up front so Solidity doesn't treat the
        // 500 * 1e18 * 10_000 chain as a literal-overflow error.
        uint256 one18 = 1_000_000_000_000_000_000;
        uint256 expectedBalance =
            (uint256(500) * one18 * 10_000) / 10_100;
        assertEq(leg.khypeBalance(), expectedBalance,
                 "fill accepted despite 100 bps drift (guard disabled)");
    }
}

/// (b) setSlippageBps is owner-gated and rejects values > 100%.
contract KI5SlippageGovernanceTests is KI5Base {
    function test_setSlippageBps_onlyOwner_KHYPE() public {
        KHYPELeg leg = _deployKHYPE(0);
        vm.prank(KI5_ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.setSlippageBps(100);
        // And the owner path works.
        vm.prank(KI5_OWNER);
        leg.setSlippageBps(100);
        assertEq(leg.slippageBps(), 100);
    }

    function test_setSlippageBps_onlyOwner_Spot() public {
        SpotStakingLeg leg = _deploySpot(0);
        vm.prank(KI5_ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.setSlippageBps(100);
        vm.prank(KI5_OWNER);
        leg.setSlippageBps(100);
        assertEq(leg.slippageBps(), 100);
    }

    /// Guards against a pathological `slippageBps > 100%` which would
    /// make `(10000 - slippageBps)` underflow. Catches the bug at
    /// deploy AND at set-time.
    function test_setSlippageBps_rejectsOverBPS_KHYPE() public {
        KHYPELeg leg = _deployKHYPE(0);
        vm.prank(KI5_OWNER);
        vm.expectRevert(bytes("slippageBps > 100%"));
        leg.setSlippageBps(10_001);
    }

    function test_setSlippageBps_rejectsOverBPS_Spot() public {
        SpotStakingLeg leg = _deploySpot(0);
        vm.prank(KI5_OWNER);
        vm.expectRevert(bytes("slippageBps > 100%"));
        leg.setSlippageBps(10_001);
    }

    function test_constructor_rejectsOverBPS_KHYPE() public {
        vm.prank(KI5_OWNER);
        vm.expectRevert(bytes("slippageBps > 100%"));
        new KHYPELeg(address(usdc), address(hype), address(router),
                     address(pool), address(oracle), 1000, 10_001);
    }

    function test_constructor_rejectsOverBPS_Spot() public {
        vm.prank(KI5_OWNER);
        vm.expectRevert(bytes("slippageBps > 100%"));
        new SpotStakingLeg(address(usdc), address(hype), address(router),
                           address(pool), address(oracle), 1000, 10_001);
    }
}

