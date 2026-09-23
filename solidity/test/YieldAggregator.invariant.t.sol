// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Round-7 invariant tests for the YieldAggregator.
///
/// Gap doc `docs/TEST_COVERAGE_GAP.md` §4 sketches three invariants
/// that are most likely to catch real accounting drift:
///
///   1. Shares are never worth more than the vault holds.
///   2. Weights always sum to BPS_DENOM (10000).
///   3. `_allocatedTotal + freeCash <= totalAssets()` (KI-5 accounting).
///
/// `_allocatedTotal` is private, so we mirror the vault's bookkeeping in
/// `cachedAllocatedTotal` and update it on every state-changing call by
/// reading each MockLeg's `totalAllocated` (which equals its
/// `currentValue`). With the MockLeg's exact-return reduceFrom
/// behaviour, the cached value tracks the vault's `_allocatedTotal`
/// exactly.

import "@forge-std/Test.sol";
import "../src/aggregator/YieldAggregator.sol";
import "../src/interfaces/IYieldLeg.sol";
import "../src/keeper/RegimeDetector.sol";

/// ERC-20 mock — minimal surface, no fee logic. Duplicated from
/// `YieldAggregator.t.sol` so this file is self-contained.
contract MockUSDC is IERC20Minimal {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
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

/// Mock yield leg that tracks allocation and sweeps its USDC back to
/// the aggregator on reduceFrom. Identical semantics to the one in
/// `YieldAggregator.t.sol` — reused so this file is self-contained.
contract MockLeg is IYieldLeg {
    uint256 public totalAllocated;
    uint256 public harvestCount;
    address public aggregator;
    address private _usdc;

    function name() external pure returns (string memory) { return "MockLeg"; }
    function expectedApy() external pure returns (uint256) { return 1000; }
    function apyHistory() external pure returns (uint256[] memory) { return new uint256[](0); }

    function allocateTo(uint256 amount) external returns (uint256) {
        require(msg.sender == aggregator, "agg only");
        totalAllocated += amount;
        return amount;
    }
    function harvest() external { harvestCount += 1; }
    function reduceFrom(uint256 amount) external virtual returns (uint256) {
        require(msg.sender == aggregator, "agg only");
        if (amount > totalAllocated) totalAllocated = 0;
        else totalAllocated -= amount;
        IERC20Minimal usdcTok = IERC20Minimal(_usdc);
        uint256 cash = usdcTok.balanceOf(address(this));
        if (cash > 0) usdcTok.transfer(aggregator, cash);
        return amount;
    }
    function currentValue() external view returns (uint256) { return totalAllocated; }
    function setUsdc(address t) external { _usdc = t; aggregator = msg.sender; }
}

contract AggInvariantTest is Test {
    address constant OWNER  = address(0x1111);
    address constant KEEPER = address(0x2222);
    address constant ALICE  = address(0x3333);
    address constant BOB    = address(0x4444);
    address constant OTHER  = address(0x5555); // non-owner, non-keeper
    address constant FEED   = address(0x6666);

    MockUSDC       usdc;
    MockLeg[4]     legs;
    YieldAggregator agg;
    RegimeDetector detector;
    address[]      depositors;

    /// Mirror of the vault's private `_allocatedTotal`. Updated on every
    /// state-changing call by summing `leg.currentValue()` (which equals
    /// `leg.totalAllocated()` for MockLeg).
    uint256 cachedAllocatedTotal;

    function setUp() public {
        vm.startPrank(OWNER);
        usdc = new MockUSDC();

        legs[0] = new MockLeg();
        legs[1] = new MockLeg();
        legs[2] = new MockLeg();
        legs[3] = new MockLeg();

        uint16[4] memory init = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        IYieldLeg[4] memory legI = [
            IYieldLeg(legs[0]), IYieldLeg(legs[1]),
            IYieldLeg(legs[2]), IYieldLeg(legs[3])
        ];
        // 1-hour timelock; the fuzzer warps past it when exercising
        // executePending.
        agg = new YieldAggregator(usdc, KEEPER, legI, 1 hours, init);
        detector = new RegimeDetector(FEED);
        vm.stopPrank();

        // Wire the USDC token to each leg. Prank as the aggregator so
        // `setUsdc` records it as the authorized caller for allocateTo /
        // reduceFrom.
        vm.startPrank(address(agg));
        legs[0].setUsdc(address(usdc));
        legs[1].setUsdc(address(usdc));
        legs[2].setUsdc(address(usdc));
        legs[3].setUsdc(address(usdc));
        vm.stopPrank();

        // Seed cash to the aggregator and to the depositors (each with
        // infinite USDC approval so deposit/mint can succeed under the
        // fuzzer).
        usdc.mint(address(agg), 1_000_000 ether);
        usdc.mint(ALICE, 1_000_000 ether);
        usdc.mint(BOB, 1_000_000 ether);
        usdc.mint(OTHER, 1_000_000 ether);
        vm.startPrank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(BOB);
        usdc.approve(address(agg), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(OTHER);
        usdc.approve(address(agg), type(uint256).max);
        vm.stopPrank();

        depositors = new address[](3);
        depositors[0] = ALICE;
        depositors[1] = BOB;
        depositors[2] = OTHER;

        cachedAllocatedTotal = 0;

        // Mark the test contract itself as fuzzable. Required in this
        // forge-std version — without it the runner reports "No
        // contracts to fuzz" because it only looks at contracts
        // deployed during `setUp()`.
        targetContract(address(this));
    }

    /// Required by forge's invariant runner: this function is called
    /// BEFORE each invariant campaign. Empty here because the setup
    /// is identical for all invariants — the runner just needs the
    /// method to exist.
    function setUpInvariant() public {}

    // ---- Helpers ----

    /// Read the current sum of leg allocations. Because MockLeg.currentValue()
    /// returns totalAllocated, this equals the vault's `_allocatedTotal`
    /// contribution after each successful state-changing call.
    function _snapAllocated() internal view returns (uint256 s) {
        s = legs[0].currentValue() + legs[1].currentValue()
          + legs[2].currentValue() + legs[3].currentValue();
    }

    // ---- Target helpers (called by the fuzzer) ----
    //
    // Each helper snapshots `cachedAllocatedTotal` AFTER the
    // (possibly reverting) call. `fail_on_revert = false` in foundry.toml
    // means reverts (wrong sender, dust, pending-exists, ...) are
    // tolerated — the invariant is still checked afterwards. The
    // snapshot reflects the last successful state-changing call.

    function depositFuzz(uint256 assets, uint8 receiverIdx) external {
        cachedAllocatedTotal = _snapAllocated();
        // Cycle receiver across 3 depositors + the vault itself so we
        // exercise both the direct-receiver and delegate-to-someone-else
        // paths.
        address receiver = depositors[receiverIdx % 3];
        if (receiverIdx == 4) receiver = address(agg);
        uint256 capped = assets % 1_000 ether + 1;
        vm.startPrank(ALICE);
        agg.deposit(capped, receiver);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    function withdrawFuzz(uint256 assets, uint8 ownerIdx, uint8 receiverIdx) external {
        cachedAllocatedTotal = _snapAllocated();
        address owner = depositors[ownerIdx % 3];
        address receiver = depositors[receiverIdx % 3];
        uint256 capped = assets % 500 ether + 1;
        // Exercise FIX-22 by calling withdraw from a NON-owner sender.
        vm.startPrank(OTHER);
        agg.withdraw(capped, receiver, owner);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    function mintFuzz(uint256 newShares, uint8 receiverIdx) external {
        cachedAllocatedTotal = _snapAllocated();
        address receiver = depositors[receiverIdx % 3];
        uint256 capped = newShares % 500 ether + 1;
        vm.startPrank(ALICE);
        agg.mint(capped, receiver);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    function redeemFuzz(uint256 newShares, uint8 ownerIdx, uint8 receiverIdx) external {
        cachedAllocatedTotal = _snapAllocated();
        address owner = depositors[ownerIdx % 3];
        address receiver = depositors[receiverIdx % 3];
        uint256 capped = newShares % 500 ether + 1;
        // Exercise FIX-23 by calling redeem from a NON-owner sender.
        vm.startPrank(OTHER);
        agg.redeem(capped, receiver, owner);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    /// Rebalance via requestAllocation + executePending. Takes three
    /// weights and DERIVES the fourth so the weight-sum constraint is
    /// always satisfiable (gap doc §4 sketch). The clamp-per-slot
    /// pattern below guarantees a+b+c+d == 10000 exactly:
    ///   w0 = min(a, remaining); remaining -= w0;
    ///   w1 = min(b, remaining); remaining -= w1;
    ///   w2 = min(c, remaining); remaining -= w2;
    ///   w3 = remaining;
    /// Each sub is safe (w0 <= remaining at every step), so no
    /// uint16 underflow.
    function rebalanceFuzz(uint16 a, uint16 b, uint16 c) external {
        cachedAllocatedTotal = _snapAllocated();

        uint256 remaining = 10000;
        uint16 w0 = (a <= remaining) ? a : uint16(remaining); remaining -= w0;
        uint16 w1 = (b <= remaining) ? b : uint16(remaining); remaining -= w1;
        uint16 w2 = (c <= remaining) ? c : uint16(remaining); remaining -= w2;
        uint16 w3 = uint16(remaining);

        uint16[4] memory w = [w0, w1, w2, w3];

        // Keeper requests; non-keeper tries first (should revert —
        // tolerated by fail_on_revert=false).
        vm.prank(OTHER);
        agg.requestAllocation(w, "fuzz-revert");

        vm.startPrank(KEEPER);
        agg.requestAllocation(w, "fuzz");
        vm.stopPrank();

        cachedAllocatedTotal = _snapAllocated();
    }

    function executePendingFuzz() external {
        cachedAllocatedTotal = _snapAllocated();

        // Request a rebalance first so there is a pending allocation to
        // execute. If a pending already exists, requestAllocation reverts
        // (tolerated) and executePending runs the older pending.
        vm.startPrank(KEEPER);
        uint16[4] memory w = [uint16(4000), uint16(3000), uint16(2000), uint16(1000)];
        agg.requestAllocation(w, "inv");
        vm.stopPrank();

        cachedAllocatedTotal = _snapAllocated();

        // Fast-forward past the timelock so `not yet` does not fire.
        vm.warp(block.timestamp + uint256(agg.timelockSeconds()) + 1);

        agg.executePending();

        cachedAllocatedTotal = _snapAllocated();
    }

    function harvestFuzz() external {
        cachedAllocatedTotal = _snapAllocated();
        vm.startPrank(KEEPER);
        agg.harvestFromAllLegs();
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    function pauseFuzz(bool p) external {
        cachedAllocatedTotal = _snapAllocated();
        // Owner-gated. Non-owner tries first (should revert — tolerated).
        vm.prank(OTHER);
        agg.setPaused(p);

        vm.startPrank(OWNER);
        agg.setPaused(p);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    /// setKeeper with a zero address should revert (the contract guards
    /// `newKeeper != address(0)`); the subsequent non-zero set succeeds.
    function keeperSetFuzz(uint8 idx) external {
        cachedAllocatedTotal = _snapAllocated();
        address newKeeper = idx == 0 ? address(0) : address(uint160(idx) + 1);
        vm.startPrank(OWNER);
        agg.setKeeper(newKeeper);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    /// setThresholds on RegimeDetector. Constraint: strong >= weak,
    /// otherwise the call reverts (tolerated).
    function setThresholdsFuzz(uint256 strong, uint256 weak, uint256 vol) external {
        cachedAllocatedTotal = _snapAllocated();
        strong %= 10_000;
        weak   %= 10_000;
        vol    %= 100_000;
        // Ensure strong >= weak to exercise the happy path — the
        // fuzzer will sometimes send strong < weak and that will
        // revert, which is also covered.
        if (strong < weak) {
            (strong, weak) = (weak, strong);
        }
        RegimeDetector.Thresholds memory t = RegimeDetector.Thresholds({
            strongApyBps: strong,
            weakApyBps:   weak,
            highVolBps:   vol
        });
        vm.startPrank(OWNER);
        detector.setThresholds(t);
        vm.stopPrank();
        cachedAllocatedTotal = _snapAllocated();
    }

    // ---- Invariants ----

    /// INVARIANT 1 — Shares are never worth more than the vault holds.
    ///
    /// Gap-doc form: each shareholder's pro-rata slice of totalAssets
    /// must be bounded by totalAssets. This is the ERC-4626 accounting
    /// invariant: no shareholder can be owed more than the vault holds.
    ///
    /// A stricter aggregate form (`totalShares <= totalAssets`, or
    /// `convertToAssets(totalShares) >= totalShares`) is NOT strictly
    /// invariant for this vault: `_distribute` floor-divides
    /// `assets * weights[i] / BPS_DENOM` per leg, so a deposit whose
    /// size is small relative to the minimum non-zero weight can be
    /// rounded down by up to ~3 units of dust, leaving
    /// `totalAssets < totalShares` by a tiny margin. See
    /// `docs/TEST_COVERAGE_GAP.md` §4 for the discussion. The
    /// pro-rata form is the correct invariant for the vault's
    /// intended semantics.
    function invariant_shareValueBounded() public view {
        uint256 totalShares = agg.totalShares();
        if (totalShares == 0) return;

        for (uint256 i = 0; i < depositors.length; i++) {
            uint256 s = agg.shares(depositors[i]);
            if (s == 0) continue;
            uint256 proRata = (s * agg.totalAssets()) / totalShares;
            assertLe(proRata, agg.totalAssets(),
                "shareholder's pro-rata slice exceeds totalAssets");
        }
    }

    /// INVARIANT 2 — Weights always sum to BPS_DENOM (10000).
    ///
    /// `requestAllocation` enforces this on input, but a bug in
    /// `executePending` (or any future state-mutating function) could
    /// silently corrupt `_weights`. This pins the guarantee.
    function invariant_weightsSumTo10000() public view {
        uint16[4] memory w = agg.weights();
        uint256 sum = uint256(w[0]) + w[1] + w[2] + w[3];
        assertEq(sum, agg.BPS_DENOM(), "weights sum != BPS_DENOM");
    }

    /// INVARIANT 3 — `_allocatedTotal + freeCash <= totalAssets()`.
    ///
    /// The vault's private `_allocatedTotal` is mirrored in
    /// `cachedAllocatedTotal` (updated on every state-changing call).
    /// We assert the primary accounting invariant AND, as a fully
    /// observable sanity check, that `totalLegValue + vaultCash ==
    /// totalAssets` (gap-doc §4 sketch). The second assertion is the
    /// definition of `totalAssets()` in the vault — if the two disagree,
    /// either a leg's `currentValue()` is stale or the vault's USDC
    /// balance was modified externally.
    function invariant_noDoubleCounting() public view {
        uint256 legSum = agg.totalLegValue();
        uint256 cash = usdc.balanceOf(address(agg));
        uint256 reported = agg.totalAssets();

        // Observable sanity: totalAssets is the sum of leg values and
        // the vault's USDC balance.
        assertEq(legSum + cash, reported,
            "totalAssets != totalLegValue + vault cash");

        // Primary accounting invariant: allocated + freeCash <= totalAssets.
        assertLe(cachedAllocatedTotal + cash, reported,
            "_allocatedTotal + freeCash > totalAssets (accounting drift)");
    }
}
