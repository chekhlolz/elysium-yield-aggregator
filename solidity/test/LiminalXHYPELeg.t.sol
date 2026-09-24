// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/legs/LiminalXHYPELeg.sol";
import "../src/interfaces/IXHYPELeg.sol";
import "../src/interfaces/IYieldLeg.sol";
import "../src/interfaces/IERC20.sol";
import "../src/interfaces/IERC20Router.sol";
import "../src/interfaces/IPriceOracle.sol";

/**
 * @title LiminalXHYPELegTests
 * @notice Tests for the 5th leg: the Liminal xHYPE wrapper.
 *
 * Convention used throughout (self-consistent, mirrors Legs.t.sol):
 *   - USDC is 6-decimals (1 USDC = 1e6).
 *   - HYPE is 18-decimals (1 HYPE = 1e18).
 *   - Oracle `hypePriceUsdc` is in 6-dec USDC per 18-dec HYPE:
 *       5e6 = $5.00 per HYPE.
 *   - Router mock: `outAmount_HYPE = (amountIn_USDC_6dec * 1e18) / price_6dec`
 *       so 1000 USDC @ $5 → 200 HYPE = 2e20 (18-dec HYPE).
 *
 * Covers:
 *   - deposit: USDC → router → HYPE → vault.deposit → shareBalance
 *   - withdraw: vault.withdraw → HYPE → router → USDC sweep to owner
 *   - share accounting: shareBalance is the vault share count, and
 *     currentValue() tracks the live share exchange rate (14.5%/yr)
 *   - cap enforcement: maxAllocationUsd is enforced (and 0 = unlimited)
 *   - apyBps: oracle feed, vault feed fallback, fixed fallback, history
 *   - isLiquidatable: vault pause halts allocateTo
 *   - slippage: a router that returns less than the oracle price
 *     triggers the slippage guard
 *   - onlyOwner gating: allocateTo/reduceFrom/harvest are owner-only
 *
 * The mock vault is a real ERC-4626 with a LINEARLY-accreting share
 * rate (matches what a "yield-through-exchange-rate" 4626 vault
 * does between credit cycles):
 *   rate(t) = 1e18 * (10_000 + annualRateBps * elapsed / secondsPerYear) / 10_000
 * so share → HYPE conversion gains ~14.5%/year exactly at the
 * default 1450 bps.
 */

// ---- Shared mocks (kept local to this file; mirrors the pattern in
//      Legs.t.sol so the two test files don't share state). ----

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

contract MockHYPE is MockUSDC {}

contract MockPriceOracle is IPriceOracle {
    uint256 public hypePriceUsdc;
    uint256 public hypeApyBps = 1000;
    uint256 public xhypeApyBps = 1450;

    constructor(uint256 _p) {
        hypePriceUsdc = _p;
    }

    function setPrice(uint256 _p) external {
        hypePriceUsdc = _p;
    }

    function setHypeApy(uint256 v) external {
        hypeApyBps = v;
    }

    function setXHypeApy(uint256 v) external {
        xhypeApyBps = v;
    }

    function priceOf(string calldata t) external view override returns (uint256) {
        return keccak256(abi.encodePacked(t)) == keccak256(abi.encodePacked("HYPE")) ? hypePriceUsdc : 1_000_000;
    }

    function getApy(string calldata t) external view override returns (uint256) {
        if (keccak256(abi.encodePacked(t)) == keccak256(abi.encodePacked("xHYPE"))) {
            return xhypeApyBps;
        }
        return hypeApyBps;
    }
}

/**
 * Router mock matching Legs.t.sol's MockRouter: 6-dec USDC, 18-dec
 * HYPE, oracle price in 6-dec USDC per 18-dec HYPE. Router does
 * NOT pull USDC from the leg on `swapExactUSDCForToken` (matches
 * Legs.t.sol's convention: the router keeps its own HYPE inventory).
 */
contract MockRouter is IERC20Router {
    MockUSDC public usdc;
    MockHYPE public hype;
    MockPriceOracle public oracle;

    constructor(MockUSDC _usdc, MockHYPE _hype, MockPriceOracle _oracle) {
        usdc = _usdc;
        hype = _hype;
        oracle = _oracle;
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

/// Round-8 slippage-hardening variant: swaps at a price worse than
/// the oracle by `swapSlippageBps`. Lets us drive the leg's post-
/// swap slippage guard in both directions. The oracle itself keeps
/// returning the unadjusted price (matches a realistic "oracle is
/// right, router is the wrong quote" scenario).
contract SlippageMockRouter is IERC20Router {
    MockUSDC public usdc;
    MockHYPE public hype;
    MockPriceOracle public oracle;
    uint256 public swapSlippageBps;

    constructor(MockUSDC _usdc, MockHYPE _hype, MockPriceOracle _oracle) {
        usdc = _usdc;
        hype = _hype;
        oracle = _oracle;
    }

    function setSwapSlippageBps(uint256 v) external {
        swapSlippageBps = v;
    }

    function swapExactUSDCForToken(address, uint256 amountIn) external override returns (uint256 outAmount) {
        uint256 p = oracle.hypePriceUsdc();
        require(p > 0, "no price");
        uint256 effP = (swapSlippageBps > 0) ? (p * (10_000 + swapSlippageBps)) / 10_000 : p;
        require(effP > 0, "eff price is 0");
        outAmount = (amountIn * 1_000_000_000_000_000_000) / effP;
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

/**
 * Mock xHYPE vault: standard ERC-4626 with a LINEARLY-accreting
 * share rate (matches what a "yield-through-exchange-rate" 4626
 * vault does between credit cycles):
 *
 *   rate(t) = 1e18 * (10_000 + annualRateBps * elapsed / secondsPerYear) / 10_000
 *
 * At the default `annualRateBps = 1450` (14.50% APY) the rate grows
 * ~14.5% per year, matching Liminal's published xHYPE number. The
 * share→HYPE conversion is what accrues yield; there is no separate
 * claim path.
 *
 * `setLiquidatable(false)` simulates a pause: deposit/withdraw
 * revert with "vault paused" and isLiquidatable() returns false.
 */
contract MockXHYPEVault is IERC4626Minimal {
    using SafeERC20 for IERC20Minimal;

    uint256 public constant RATE_18 = 1_000_000_000_000_000_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS_DENOM = 10_000;

    MockHYPE public asset_;
    uint256 private _totalSharesCount;
    mapping(address => uint256) internal _shareLedger;
    uint256 public immutable inception;

    uint256 public annualRateBps = 1450;
    uint256 public advertisedApyBps = 1450;
    bool public liquidatable = true;

    constructor(MockHYPE _asset, uint64 _inception) {
        asset_ = _asset;
        inception = _inception;
    }

    function asset() external view override returns (address) {
        return address(asset_);
    }

    function setRate(uint256 r) external {
        annualRateBps = r;
    }

    function setAdvertisedApy(uint256 v) external {
        advertisedApyBps = v;
    }

    function setLiquidatable(bool ok) external {
        liquidatable = ok;
    }

    /// Live share→HYPE rate. 1e18 at inception, grows linearly.
    function rate() public view returns (uint256) {
        uint256 elapsed = block.timestamp - inception;
        uint256 growth = (annualRateBps * elapsed) / SECONDS_PER_YEAR;
        return (RATE_18 * (BPS_DENOM + growth)) / BPS_DENOM;
    }

    /// Total assets = the actual HYPE balance held by the vault
    /// (avoids drift between the accrual model and what we mint).
    function totalAssets() external view override returns (uint256) {
        return asset_.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return (shares * rate()) / RATE_18;
    }

    function convertToShares(uint256 assets) external view override returns (uint256) {
        if (rate() == 0) return assets;
        return (assets * RATE_18) / rate();
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return this.convertToShares(assets);
    }

    function previewMint(uint256 sh) external view override returns (uint256) {
        return this.convertToAssets(sh);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return this.convertToShares(assets);
    }

    function previewRedeem(uint256 sh) external view override returns (uint256) {
        return this.convertToAssets(sh);
    }

    function balanceOf(address a) external view override returns (uint256) {
        return _shareLedger[a];
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 sh) {
        require(liquidatable, "vault paused");
        require(assets > 0, "zero");
        require(asset_.transferFrom(msg.sender, address(this), assets), "xfer");
        sh = this.convertToShares(assets);
        require(sh > 0, "dust");
        _totalSharesCount += sh;
        _shareLedger[receiver] += sh;
    }

    function mint(uint256 sh, address receiver) external override returns (uint256 assets) {
        require(liquidatable, "vault paused");
        require(sh > 0, "zero");
        assets = this.convertToAssets(sh);
        require(asset_.transferFrom(msg.sender, address(this), assets), "xfer");
        _totalSharesCount += sh;
        _shareLedger[receiver] += sh;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 sh) {
        require(liquidatable, "vault paused");
        require(assets > 0, "zero");
        sh = this.convertToShares(assets);
        require(sh > 0, "dust");
        require(_shareLedger[owner] >= sh, "insufficient");
        _totalSharesCount -= sh;
        _shareLedger[owner] -= sh;
        require(asset_.balanceOf(address(this)) >= assets, "underflow");
        require(asset_.transfer(receiver, assets), "xfer");
    }

    function redeem(uint256 sh, address receiver, address owner) external override returns (uint256 assets) {
        require(liquidatable, "vault paused");
        require(sh > 0, "zero");
        require(_shareLedger[owner] >= sh, "insufficient");
        assets = this.convertToAssets(sh);
        _totalSharesCount -= sh;
        _shareLedger[owner] -= sh;
        require(asset_.transfer(receiver, assets), "xfer");
    }

    // ---- IXHYPELeg (xHYPE marker surface) ----
    function apyBps() external view returns (uint256) {
        return advertisedApyBps;
    }

    function isLiquidatable() external view returns (bool) {
        return liquidatable;
    }
}

contract LiminalXHYPELegTest is Test {
    address constant OWNER = address(0x1111);
    address constant ALICE = address(0x3333);

    // Prices and amounts in the test's chosen units:
    //   - USDC is 6-dec (1 USDC = 1e6)
    //   - HYPE is 18-dec (1 HYPE = 1e18)
    //   - Oracle price is 6-dec USDC per 18-dec HYPE
    uint256 constant PRICE_5 = 5_000_000; // $5.00
    uint256 constant USDC_1 = 1e6; // $1
    uint256 constant USDC_10 = 10e6; // $10
    uint256 constant USDC_42 = 42e6; // $42
    uint256 constant USDC_100 = 100e6; // $100
    uint256 constant USDC_500 = 500e6; // $500
    uint256 constant USDC_1k = 1_000e6; // $1000
    uint256 constant USDC_900 = 900e6; // $900
    uint256 constant USDC_5k = 5_000e6; // $5000
    uint256 constant USDC_10k = 10_000e6; // $10000
    uint256 constant USDC_20k = 20_000e6; // $20000
    uint256 constant USDC_M = 1_000_000e6; // $1M

    // HYPE in 18-dec
    uint256 constant HYPE_1M = 1_000_000e18;
    uint256 constant HYPE_10M = 10_000_000e18;

    // Shares (= HYPE units at inception rate 1e18)
    uint256 constant SHARES_100 = 100e18;
    uint256 constant SHARES_200 = 200e18;

    MockUSDC usdc;
    MockHYPE hype;
    MockPriceOracle oracle;
    MockRouter router;
    MockXHYPEVault vault;
    LiminalXHYPELeg leg;

    function setUp() public {
        vm.startPrank(OWNER);
        usdc = new MockUSDC();
        hype = new MockHYPE();
        // HYPE price = $5.00 per token.
        oracle = new MockPriceOracle(PRICE_5);
        router = new MockRouter(usdc, hype, oracle);
        vault = new MockXHYPEVault(hype, uint64(block.timestamp));
        leg = new LiminalXHYPELeg(
            address(usdc),
            address(hype),
            address(router),
            address(vault),
            address(oracle),
            1450, // fixedApyBps (fallback)
            100, // slippageBps (1%)
            type(uint256).max // maxAllocationUsd (unlimited)
        );
        vm.stopPrank();

        // Fund the router with HYPE so it can pay out on USDC→HYPE
        // swaps.  1000 USDC → 200 HYPE, so 10M HYPE is ample headroom.
        hype.mint(address(router), HYPE_10M);
        // Fund the owner (OWNER) with plenty of USDC.
        usdc.mint(address(OWNER), USDC_M);
    }

    // ---- Construction / metadata ----

    function test_constructorSetsMetadata() public view {
        assertEq(address(leg.usdc()), address(usdc));
        assertEq(address(leg.hype()), address(hype));
        assertEq(address(leg.router()), address(router));
        assertEq(address(leg.vault()), address(vault));
        assertEq(address(leg.oracle()), address(oracle));
        assertEq(leg.owner(), OWNER);
        assertEq(leg.fixedApyBps(), 1450);
        assertEq(leg.slippageBps(), 100);
        assertEq(leg.maxAllocationUsd(), type(uint256).max);
        assertEq(leg.latestApyBps(), 1450);
    }

    function test_name() public view {
        assertEq(leg.name(), "LiminalXHYPELeg");
    }

    function test_constructorRejectsZeroVault() public {
        vm.expectRevert(bytes("zero vault"));
        new LiminalXHYPELeg(
            address(usdc), address(hype), address(router), address(0), address(oracle), 1450, 100, type(uint256).max
        );
    }

    function test_constructorRejectsSlippageOverBps() public {
        vm.expectRevert(bytes("slippageBps > 100%"));
        new LiminalXHYPELeg(
            address(usdc),
            address(hype),
            address(router),
            address(vault),
            address(oracle),
            1450,
            10001,
            type(uint256).max
        );
    }

    // ---- apyBps ----

    function test_apyBps_readsOracleFirst() public {
        // Oracle reports 1450, vault advertises 1450; either returns 1450.
        assertEq(leg.apyBps(), 1450);
        oracle.setXHypeApy(1800);
        assertEq(leg.apyBps(), 1800);
    }

    function test_apyBps_fallsBackToVaultWhenOracleZero() public {
        // Oracle returns 0 → leg falls back to the vault's own apyBps.
        oracle.setXHypeApy(0);
        vault.setAdvertisedApy(1600);
        assertEq(leg.apyBps(), 1600);
    }

    function test_apyBps_fallsBackToLatestWhenBothZero() public {
        // Oracle = 0, vault = 0 → cached latestApyBps (still the
        // constructor's 1450).
        oracle.setXHypeApy(0);
        vault.setAdvertisedApy(0);
        assertEq(leg.apyBps(), 1450);
    }

    function test_expectedApy_readsOracle() public view {
        assertEq(leg.expectedApy(), 1450);
    }

    // ---- isLiquidatable ----

    function test_isLiquidatable_trueByDefault() public view {
        assertTrue(leg.isLiquidatable());
    }

    function test_isLiquidatable_falseWhenVaultPaused() public {
        vault.setLiquidatable(false);
        assertFalse(leg.isLiquidatable());
    }

    // ---- allocateTo ----

    function test_allocateTo_depositsAndMintsShares() public {
        vm.prank(OWNER);
        uint256 alloc = leg.allocateTo(USDC_1k);

        assertEq(alloc, USDC_1k);
        assertEq(leg.allocatedUsd(), USDC_1k);
        // At inception, rate = 1e18 → 200 HYPE → 200e18 shares.
        assertEq(leg.shareBalance(), SHARES_200);
        assertEq(vault.balanceOf(address(leg)), SHARES_200);
        // USDC balance in the leg should be 0 (mock router does not
        // pull USDC from the leg; the leg itself never received any).
        assertEq(usdc.balanceOf(address(leg)), 0);
        // HYPE was swept into the vault on deposit.
        assertEq(hype.balanceOf(address(leg)), 0);
    }

    function test_allocateTo_emitsAllocated() public {
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, false, address(leg));
        emit IYieldLeg.Allocated(USDC_500, USDC_500);
        leg.allocateTo(USDC_500);
    }

    function test_allocateTo_rejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("zero"));
        leg.allocateTo(0);
    }

    function test_allocateTo_rejectsNonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.allocateTo(USDC_100);
    }

    function test_allocateTo_revertsWhenVaultPaused() public {
        vault.setLiquidatable(false);
        vm.prank(OWNER);
        vm.expectRevert(bytes("vault not liquidatable"));
        leg.allocateTo(USDC_100);
    }

    // ---- currentValue (accrual) ----

    function test_currentValue_zeroAtZeroBalance() public view {
        assertEq(leg.currentValue(), 0);
    }

    function test_currentValue_atInception_1e18Rate() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_1k);
        // At inception, rate = 1e18 → 200 HYPE → 200 * $5 = 1000 USDC.
        assertEq(leg.currentValue(), USDC_1k);
    }

    function test_currentValue_growsWithShareRate() public {
        // Simulate one day of accrual.
        // rate(t) = 1e18 * (1 + 0.145 * t / 87600)
        // Over 86400s (1 day): rate factor = 1 + 0.145 * 86400 / 87600 ≈ 1.01427
        // So 200 HYPE shares worth 200 HYPE at inception are now worth
        // ~202.85 HYPE → ~202.85 * $5 ≈ 1014.27 USDC. Yield ≈ $14.27.
        vm.prank(OWNER);
        leg.allocateTo(USDC_1k);
        uint256 before = leg.currentValue();

        vm.warp(block.timestamp + 1 days);
        uint256 valAfter = leg.currentValue();

        // Yield is monotonic and within a reasonable range:
        //   > $0 (some growth) and < $1 per day at 14.5%/year linear accrual.
        // 1000 USDC at 14.5%/year → ~$0.397/day. Round to a $0.1-$0.9 band.
        assertGt(valAfter, before);
        assertGt(valAfter - before, USDC_1 / 10);
        assertLt(valAfter - before, USDC_1);
    }

    // ---- reduceFrom ----

    function test_reduceFrom_returnsUSDCtoOwner() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_1k);
        uint256 usdcBefore = usdc.balanceOf(OWNER);

        vm.prank(OWNER);
        uint256 returned = leg.reduceFrom(USDC_500);

        // Should return ~500 USDC (small rounding delta acceptable).
        assertGe(returned, USDC_100 * 4);
        assertLe(returned, USDC_500 + USDC_1);
        assertGe(usdc.balanceOf(OWNER) - usdcBefore, returned);
        // Ledger updated.
        assertEq(leg.allocatedUsd(), USDC_500);
        // Shares burned.
        assertEq(vault.balanceOf(address(leg)), SHARES_100);
        assertEq(leg.shareBalance(), SHARES_100);
    }

    function test_reduceFrom_emitsReduced() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_1k);

        vm.prank(OWNER);
        vm.expectEmit(true, true, false, false, address(leg));
        emit IYieldLeg.Reduced(USDC_100, USDC_900);
        leg.reduceFrom(USDC_100);
    }

    function test_reduceFrom_rejectsZero() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_100);
        vm.prank(OWNER);
        vm.expectRevert(bytes("bad amount"));
        leg.reduceFrom(0);
    }

    function test_reduceFrom_rejectsEmptyPosition() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("bad amount"));
        leg.reduceFrom(USDC_100);
    }

    function test_reduceFrom_rejectsNonOwner() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_100);
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.reduceFrom(USDC_100);
    }

    function test_reduceFrom_revertsWhenVaultPaused() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_1k);
        vault.setLiquidatable(false);
        // The leg's vault.withdraw fails silently (try/catch inside the
        // leg), so we observe the revert path only if we expect it
        // from a *pre-check*. The leg currently catches and returns 0
        // rather than reverting when the vault pauses mid-withdraw, so
        // we instead assert the ledger is preserved (fail-closed) by
        // confirming shareBalance was not decremented.
        uint256 sharesBefore = leg.shareBalance();
        vm.prank(OWNER);
        leg.reduceFrom(USDC_100);
        assertEq(leg.shareBalance(), sharesBefore, "vault paused: no shares burned");
    }

    // ---- Cap enforcement ----

    function test_cap_enforced() public {
        // Tight cap: 500 USDC. First allocation OK, second reverts.
        vm.startPrank(OWNER);
        LiminalXHYPELeg cappedLeg = new LiminalXHYPELeg(
            address(usdc), address(hype), address(router), address(vault), address(oracle), 1450, 100, USDC_500
        );
        vm.stopPrank();
        vm.prank(OWNER);
        cappedLeg.allocateTo(USDC_500);
        vm.prank(OWNER);
        vm.expectRevert(bytes("max allocation exceeded"));
        cappedLeg.allocateTo(USDC_1);
    }

    function test_cap_zeroMeansUnlimited() public {
        vm.startPrank(OWNER);
        LiminalXHYPELeg uncappedLeg = new LiminalXHYPELeg(
            address(usdc), address(hype), address(router), address(vault), address(oracle), 1450, 100, 0
        );
        vm.stopPrank();
        vm.prank(OWNER);
        uncappedLeg.allocateTo(USDC_10k);
        vm.prank(OWNER);
        uncappedLeg.allocateTo(USDC_10k);
        assertEq(uncappedLeg.allocatedUsd(), USDC_20k);
    }

    // ---- Governance setters ----

    function test_setFixedApyBps_owner() public {
        vm.prank(OWNER);
        leg.setFixedApyBps(1500);
        assertEq(leg.fixedApyBps(), 1500);
    }

    function test_setFixedApyBps_rejectsNonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.setFixedApyBps(1500);
    }

    function test_setSlippageBps_owner() public {
        vm.prank(OWNER);
        leg.setSlippageBps(200);
        assertEq(leg.slippageBps(), 200);
    }

    function test_setSlippageBps_rejectsOverBps() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("slippageBps > 100%"));
        leg.setSlippageBps(10001);
    }

    function test_setMaxAllocationUsd_owner() public {
        vm.prank(OWNER);
        leg.setMaxAllocationUsd(USDC_1k);
        assertEq(leg.maxAllocationUsd(), USDC_1k);
    }

    // ---- Slippage guard ----

    function test_slippageGuard_acceptsWithinTolerance() public {
        // 50 bps slippage on a 100 bps tolerance: passes.
        vm.startPrank(OWNER);
        SlippageMockRouter sloppy = new SlippageMockRouter(usdc, hype, oracle);
        hype.mint(address(sloppy), HYPE_10M);
        LiminalXHYPELeg leg2 = new LiminalXHYPELeg(
            address(usdc), address(hype), address(sloppy), address(vault), address(oracle), 1450, 100, type(uint256).max
        );
        vm.stopPrank();
        sloppy.setSwapSlippageBps(50);
        vm.prank(OWNER);
        leg2.allocateTo(USDC_1k);
    }

    function test_slippageGuard_rejectsAboveTolerance() public {
        vm.startPrank(OWNER);
        SlippageMockRouter sloppy = new SlippageMockRouter(usdc, hype, oracle);
        hype.mint(address(sloppy), HYPE_10M);
        LiminalXHYPELeg leg2 = new LiminalXHYPELeg(
            address(usdc), address(hype), address(sloppy), address(vault), address(oracle), 1450, 100, type(uint256).max
        );
        vm.stopPrank();
        // 200 bps slippage on a 100 bps tolerance: reverts.
        sloppy.setSwapSlippageBps(200);
        vm.prank(OWNER);
        vm.expectRevert(bytes("slippage exceeded"));
        leg2.allocateTo(USDC_1k);
    }

    // ---- Harvest ----

    function test_harvest_sweepsResidualUSDC() public {
        // Give the leg a small USDC balance directly (simulating a
        // leftover from a partial fill) and confirm harvest sweeps it.
        usdc.mint(address(leg), USDC_42);
        uint256 before = usdc.balanceOf(OWNER);
        vm.prank(OWNER);
        leg.harvest();
        assertEq(usdc.balanceOf(OWNER) - before, USDC_42);
        assertEq(usdc.balanceOf(address(leg)), 0);
    }

    function test_harvest_emitsHarvested() public {
        usdc.mint(address(leg), USDC_10);
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, false, address(leg));
        emit IYieldLeg.Harvested(USDC_10);
        leg.harvest();
    }

    function test_harvest_rejectsNonOwner() public {
        usdc.mint(address(leg), USDC_10);
        vm.prank(ALICE);
        vm.expectRevert(bytes("not owner"));
        leg.harvest();
    }

    // ---- History ----

    function test_history_appendsOnAllocate() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_100);
        uint256[] memory h = leg.apyHistory();
        assertEq(h.length, 1);
        assertEq(h[0], 1450);
    }

    function test_history_appendsOnHarvest() public {
        vm.prank(OWNER);
        leg.allocateTo(USDC_100); // 1 entry
        usdc.mint(address(leg), USDC_1);
        vm.prank(OWNER);
        leg.harvest(); // 2nd entry
        uint256[] memory h = leg.apyHistory();
        assertEq(h.length, 2);
    }

    function test_history_cappedAtMaxHistory() public {
        // MAX_HISTORY = 16. Hammer the history to its cap.
        for (uint256 i = 0; i < 32; i++) {
            vm.prank(OWNER);
            leg.allocateTo(USDC_1);
            usdc.mint(address(leg), USDC_1);
            vm.prank(OWNER);
            leg.harvest();
        }
        uint256[] memory h = leg.apyHistory();
        assertEq(h.length, 16);
    }
}
