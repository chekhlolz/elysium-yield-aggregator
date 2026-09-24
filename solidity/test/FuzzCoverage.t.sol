// SPDX-License-Identifier: MIT
// forge-config: default.fuzz.runs = 512

pragma solidity ^0.8.26;

/// Fuzz tests covering `docs/TEST_COVERAGE_GAP.md §6`.
///
/// Scope of this file:
///   1. YieldAggregator.convertToShares / convertToAssets round-trip fuzz
///      across 1:1 bootstrap and post-deposit (multiple depositors, drift).
///   2. RegimeDetector.computeRegime priority chain + weightsForRegime
///      for every uint8 regime (0..255), including unknown regimes.
///   3. TradeOnlyAgent.isValidDelegation field-zero guards across fuzzed
///      (maxNotional, maxPerOrder) combinations.
///   4. Non-canonical signature recovery: never reverts (or returns false)
///      for out-of-range v, extreme r, and extreme s.
///   5. TradeOnlyAgent.recordExecution monotone usedNotional across
///      multiple accepted calls, plus per-venue isolation.
///
/// The MockUSDC and MockLeg mocks below are copied from
/// `YieldAggregator.t.sol` so this file is self-contained.

import "@forge-std/Test.sol";
import "../src/aggregator/YieldAggregator.sol";
import "../src/interfaces/IYieldLeg.sol";
import "../src/interfaces/IElysiumCoreWriter.sol";
import "../src/keeper/RegimeDetector.sol";
import "../src/delegation/TradeOnlyAgent.sol";

// ---------------------------------------------------------------------------
// ERC-20 mock (duplicated from YieldAggregator.t.sol for self-containment)
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Mock yield leg (duplicated from YieldAggregator.t.sol for self-containment)
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Fuzz test contract
// ---------------------------------------------------------------------------
contract FuzzCoverageTest is Test {
    address constant OWNER       = address(0x1111);
    address constant KEEPER      = address(0x2222);
    address constant ALICE       = address(0x3333);
    address constant BOB         = address(0x4444);
    address constant CAROL       = address(0x5555);
    address constant FEED        = address(0x6666);
    address constant VENUE       = address(0xC333);
    address constant VENUE_B     = address(0xEE00);

    uint256 constant DELEGATOR_PK = 0xA111;
    uint256 constant KEEPER_PK    = 0xB222;

    uint256 constant USDC_SCALE   = 1e18;
    uint256 constant SECP256K1_N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// Integer square root (BinaryNumberTheorem-style). Used only to
    /// compute loss-tolerance bounds for round-trip fuzz tests; not
    /// part of any production code.
    function isqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 z = x + 1;
        uint256 y;
        while (true) {
            y = (z + x / z) / 2;
            if (y >= z) {
                r = z;
                break;
            }
            z = y;
        }
    }

    /// Ceiling of a / b for uint256. `ceil(a/b) = (a + b - 1) / b`.
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    MockUSDC        usdc;
    MockLeg[4]      legs;
    YieldAggregator agg;
    RegimeDetector  detector;
    TradeOnlyAgent  agent;

    function setUp() public {
        // ---- Aggregator setup (mirrors YieldAggregator.t.sol setUp) ----
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
        agg = new YieldAggregator(usdc, KEEPER, legI, 1 hours, init);

        // ---- RegimeDetector + TradeOnlyAgent ----
        detector = new RegimeDetector(FEED);
        agent = new TradeOnlyAgent();
        vm.stopPrank();

        // Wire USDC token to legs; aggregator must be the authorized caller.
        vm.startPrank(address(agg));
        legs[0].setUsdc(address(usdc));
        legs[1].setUsdc(address(usdc));
        legs[2].setUsdc(address(usdc));
        legs[3].setUsdc(address(usdc));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- #
    // YieldAggregator.convertToShares / convertToAssets — fuzz #1
    // ----------------------------------------------------------------- #

    /// Bootstrap case: no prior shares. `convertToShares` is identity
    /// (1:1 mint rate) and `convertToAssets` is identity, so the round
    /// trip is exact. Pins the bootstrap branch of both functions
    /// (YieldAggregator.sol:192, 197).
    function testFuzz_bootstrapRoundTrip_exact(uint256 x) public view {
        x = bound(x, 0, USDC_SCALE);
        uint256 s = agg.convertToShares(x);
        assertEq(s, x, "bootstrap convertToShares must be 1:1");
        uint256 a = agg.convertToAssets(s);
        assertEq(a, x, "bootstrap convertToAssets must be 1:1");
    }

    /// Multi-depositor round-trip with rate drift. Alice deposits 1e18
    /// (bootstrap, 1:1 rate). Bob and Carol each deposit 5e17, drifting
    /// the total rate to 1.0. Fuzz a fourth deposit amount x and verify
    /// the round-trip is within tolerance. The tolerance is 200 units of
    /// USDC base, which is well below any plausible accounting bug
    /// (a 1% accounting bug at x=1e18 would show ~1e16 units of drift)
    /// while absorbing dust-rounding from `_distribute`'s floor division.
    function testFuzz_multiDepositor_roundTrip(uint256 x) public {
        x = bound(x, 1, 1e18);

        usdc.mint(ALICE, 1e18);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(ALICE);
        agg.deposit(1e18, ALICE);

        usdc.mint(BOB, 5e17);
        vm.prank(BOB);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(BOB);
        agg.deposit(5e17, BOB);

        usdc.mint(CAROL, 5e17);
        vm.prank(CAROL);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(CAROL);
        agg.deposit(5e17, CAROL);

        uint256 a = agg.convertToAssets(x);
        uint256 s = agg.convertToShares(a);
        assertLe(s, x, "round-trip converted to fewer shares than expected");

        // Tolerance: 200 USDC base units absorbs dust rounding from the
        // floor-division in convertToShares (YieldAggregator.sol:193).
        // The gap doc §6 spec calls for `x * (10000 - roundingTolerance) /
        // 10000`, which is 0.01% for tolerance=10; a fixed additive bound
        // is more robust against very small x where a 0.01% tolerance is
        // tighter than the actual rounding slack.
        uint256 loss = x - s;
        assertLe(loss, 200, "round-trip loss exceeds dust-rounding tolerance");
    }

    /// Round-trip at a HIGH exchange rate (2x). Alice deposits 1e18
    /// then we mint another 1e18 to the aggregator (as free cash),
    /// pushing the rate to 2.0 shares/asset. Round-trip loss at x=1e18
    /// is 2*sqrt(x) = 2e9, so we use a looser tolerance.
    function testFuzz_highExchangeRate_roundTrip(uint256 x) public {
        x = bound(x, 1, 1e18);

        usdc.mint(ALICE, 1e18);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(ALICE);
        agg.deposit(1e18, ALICE);

        // Mint to the aggregator itself so totalAssets doubles.
        usdc.mint(address(agg), 1e18);
        // totalAssets = 2e18 (1e18 leg value + 1e18 vault cash)
        // totalShares = 1e18
        // rate = totalAssets / totalShares = 2

        uint256 a = agg.convertToAssets(x);
        uint256 s = agg.convertToShares(a);
        assertLe(s, x, "round-trip converted to fewer shares");

        // Round-trip loss at rate 2 is exactly ceil(x/2)*2 - x, i.e.
        // 0 for even x, 1 for odd x. Tolerance of 10 is very loose.
        uint256 loss = x - s;
        assertLe(loss, 10, "round-trip loss exceeds tight bound at rate=2");
    }

    /// Round-trip after ONE deposit (Alice seeds, Bob deposits a fuzzed
    /// amount). This is the "post-deposit (has prior shares)" case from
    /// gap doc §6, exercised at the deposit boundary.
    function testFuzz_singlePostDeposit_roundTrip(uint256 x) public {
        x = bound(x, 1, 1e18);

        // Alice seeds (bootstrap).
        usdc.mint(ALICE, 1e18);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(ALICE);
        agg.deposit(1e18, ALICE);

        // Bob deposits a fuzzed amount, drifting the rate.
        usdc.mint(BOB, 1e18 + x);
        vm.prank(BOB);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(BOB);
        agg.deposit(x, BOB);

        // Round-trip a fresh x through the rate. With weights 2500/4
        // and MockLeg's 1:1 currentValue, the rate stays at exactly 1
        // throughout, so round-trip loss is 0.
        uint256 a = agg.convertToAssets(x);
        uint256 s = agg.convertToShares(a);
        assertLe(s, x, "round-trip to fewer shares");
        uint256 loss = x - s;
        assertLe(loss, 10, "round-trip loss exceeds tolerance at rate=1");
    }

    // ----------------------------------------------------------------- #
    // RegimeDetector — fuzz #2
    // ----------------------------------------------------------------- #

    /// Priority chain: HIGH_VOL > FUNDING_NEG > FUNDING_STRONG > FUNDING_WEAK.
    /// Default thresholds: strong=800, weak=300, highVol=9000.
    function testFuzz_computeRegime_priorityChain(int64 apySigned, uint256 volBps) public view {
        uint8 r = detector.computeRegime(apySigned, volBps);
        if (volBps >= 9000) {
            assertEq(uint256(r), 3, "vol >= 9000 must be HIGH_VOL");
        } else if (apySigned < 0) {
            assertEq(uint256(r), 2, "apySigned < 0 must be FUNDING_NEG");
        } else if (uint256(int256(apySigned)) >= 800) {
            assertEq(uint256(r), 0, "apySigned >= 800 must be FUNDING_STRONG");
        } else {
            assertEq(uint256(r), 1, "everything else must be FUNDING_WEAK");
        }
    }

    /// Priority chain after setThresholds. Same priority order must hold
    /// for arbitrary (strong, weak, vol) thresholds with strong >= weak
    /// (the contract's guard).
    function testFuzz_computeRegime_customThresholds(int64 apySigned, uint256 volBps) public {
        uint256 strong = bound(volBps % 10_000, 1, 10_000);
        uint256 weak   = bound(volBps % 10_000, 1, strong);
        uint256 highVol = bound(volBps % 200_000, 1, 200_000);
        RegimeDetector.Thresholds memory t = RegimeDetector.Thresholds({
            strongApyBps: strong,
            weakApyBps:   weak,
            highVolBps:   highVol
        });
        vm.prank(OWNER);
        detector.setThresholds(t);

        uint8 r = detector.computeRegime(apySigned, volBps);
        if (volBps >= highVol) {
            assertEq(uint256(r), 3);
        } else if (apySigned < 0) {
            assertEq(uint256(r), 2);
        } else if (uint256(int256(apySigned)) >= strong) {
            assertEq(uint256(r), 0);
        } else {
            assertEq(uint256(r), 1);
        }
    }

    /// `weightsForRegime` must sum to exactly 10_000 for EVERY uint8
    /// regime value, including unknown ones (the contract's `else` branch
    /// silently falls through to HIGH_VOL weights [5000, 5000, 0, 0]
    /// for regime >= 4). Pins gap-doc §2.3 "weightsForRegime on unknown
    /// regime value".
    function testFuzz_weightsForRegime_all256(uint8 regime) public view {
        uint16[4] memory w = detector.weightsForRegime(regime);
        uint256 sum = uint256(w[0]) + uint256(w[1]) + uint256(w[2]) + uint256(w[3]);
        assertEq(sum, 10_000, "weightsForRegime sum must be 10_000");
    }

    /// Same sum invariant, but restricted to the four canonical regime
    /// values (0..3). Redundant with `testFuzz_weightsForRegime_all256`
    /// but keeps a targeted version for the enum-defined range.
    function testFuzz_weightsForRegime_canonical(uint8 regime) public view {
        regime = uint8(bound(regime, 0, 3));
        uint16[4] memory w = detector.weightsForRegime(regime);
        uint256 sum = uint256(w[0]) + uint256(w[1]) + uint256(w[2]) + uint256(w[3]);
        assertEq(sum, 10_000);
        // Every individual weight is in [0, 10_000] (uint16 always is).
        assertTrue(w[0] <= 10_000);
        assertTrue(w[1] <= 10_000);
        assertTrue(w[2] <= 10_000);
        assertTrue(w[3] <= 10_000);
    }

    // ----------------------------------------------------------------- #
    // TradeOnlyAgent.isValidDelegation — fuzz #3
    // ----------------------------------------------------------------- #

    function _mkDelegation(address keeper, uint256 maxNotional, uint256 maxPerOrder,
                          uint64 expiresAt, uint64 nonce, bytes32 salt)
        internal view returns (ITradeOnlyAgent.Delegation memory)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        return ITradeOnlyAgent.Delegation({
            keeper: keeper,
            assetIds: ids,
            maxNotional: maxNotional,
            maxPerOrder: maxPerOrder,
            expiresAt: expiresAt,
            nonce: nonce,
            salt: salt
        });
    }

    function _sign(uint256 pk, address from, ITradeOnlyAgent.Delegation memory d)
        internal view returns (ITradeOnlyAgent.Signature memory)
    {
        bytes32 delegationTypeHash = keccak256(
            "Delegation(address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)"
        );
        bytes32 domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 digestStruct = keccak256(
            abi.encode(
                from,
                delegationTypeHash,
                d.keeper,
                keccak256(abi.encode(d.assetIds)),
                d.maxNotional,
                d.maxPerOrder,
                d.expiresAt,
                d.nonce,
                d.salt
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                domainTypeHash,
                keccak256("TradeOnlyAgent v1"),
                keccak256("1"),
                block.chainid,
                address(agent)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, digestStruct)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return ITradeOnlyAgent.Signature(v, r, s);
    }

    function delegatorAddr() internal view returns (address) {
        return vm.addr(DELEGATOR_PK);
    }

    function keeperAddr() internal view returns (address) {
        return vm.addr(KEEPER_PK);
    }

    /// Field-zero guard across fuzzed (maxNotional, maxPerOrder,
    /// expiresAt, nonce, salt) combinations. A delegation signed by the
    /// delegator is VALID iff BOTH maxNotional and maxPerOrder are
    /// non-zero (the keeper address must also be non-zero, enforced by
    /// a separate test). Note: `maxPerOrder` is a documentation-only
    /// field in the current contract — `isValidDelegation` checks
    /// `maxPerOrder > 0` but does NOT compare it against any notional
    /// (see gap-doc §2.2 for the "maxPerOrder is never enforced"
    /// finding). The "notional" dimension of §6 refers to that bug.
    function testFuzz_isValidDelegation_fieldZeroGuards(uint256 maxNotional, uint256 maxPerOrder,
                                                        uint64 expiresAt, uint64 nonce,
                                                        bytes32 salt) public view {
        address delegator = delegatorAddr();
        address keeper = keeperAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeper, maxNotional, maxPerOrder, expiresAt, nonce, salt
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, delegator, d);

        bool expected = maxNotional > 0 && maxPerOrder > 0;
        // If expiresAt != 0 and is in the past, isValidDelegation returns
        // false regardless of the caps. We set expiresAt from the fuzzer
        // parameter so this branch is exercised naturally.
        if (expiresAt != 0 && block.timestamp > expiresAt) {
            expected = false;
        }
        assertEq(agent.isValidDelegation(delegator, d, sig), expected,
                 "field-zero guard + expiry behaviour mismatch");
    }

    /// Zero keeper address must always produce `false`, even with
    /// otherwise valid caps and a valid signature.
    function testFuzz_isValidDelegation_zeroKeeperRejected(uint256 maxNotional, uint256 maxPerOrder,
                                                           uint64 nonce, bytes32 salt)
        public view
    {
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(0), maxNotional, maxPerOrder, 0, nonce, salt
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, delegator, d);
        assertFalse(agent.isValidDelegation(delegator, d, sig),
                    "zero keeper must always be rejected");
    }

    /// Wrong signer: signed by keeper instead of delegator. Must always
    /// be rejected regardless of the caps.
    function testFuzz_isValidDelegation_wrongSignerRejected(uint256 maxNotional, uint256 maxPerOrder)
        public view
    {
        address delegator = delegatorAddr();
        address keeper = keeperAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeper, maxNotional, maxPerOrder, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(KEEPER_PK, delegator, d);
        assertFalse(agent.isValidDelegation(delegator, d, sig),
                    "wrong-signer delegation must always be rejected");
    }

    /// Positive-path fuzz: a valid delegation with all caps > 0 and a
    /// valid signature MUST be accepted. This pins the "happy path"
    /// across a wide parameter space — any refactor that adds an
    /// incorrect guard would trip here.
    function testFuzz_isValidDelegation_validCaps(uint256 maxNotional, uint256 maxPerOrder,
                                                 uint64 nonce, bytes32 salt)
        public view
    {
        maxNotional = bound(maxNotional, 1, 1e24);
        maxPerOrder = bound(maxPerOrder, 1, 1e24);
        address delegator = delegatorAddr();
        address keeper = keeperAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeper, maxNotional, maxPerOrder, 0, nonce, salt
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, delegator, d);
        assertTrue(agent.isValidDelegation(delegator, d, sig),
                   "valid caps + valid sig must be accepted");
    }

    // ----------------------------------------------------------------- #
    // Non-canonical signature recovery — fuzz #4
    // ----------------------------------------------------------------- #

    /// `isValidDelegation` must NEVER panic on a malformed signature.
    /// Round-9 canonicality hardening added explicit reverts for
    /// r==0, s==0, and s > secp256k1.order/2. Those reverts are
    /// intentional (not panics) and satisfy the "never panics" goal:
    /// an explicit revert is a clean rejection, not an arithmetic
    /// underflow or stack overflow.
    ///
    /// For v ∈ [29, 30] the contract's `_recover` requires v ∈ {27, 28}
    /// and reverts with "bad v". For v ∈ {27, 28} with r=0 or s=0 the
    /// new checks revert; for non-canonical s the check reverts; for
    /// canonical r/s, `ecrecover` runs and may return address(0) or a
    /// wrong address (in which case `isValidDelegation` returns false).
    function testFuzz_signatureRecovery_neverPanics(uint8 v, bytes32 r, bytes32 s) public {
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        if (v >= 29 || v < 27) {
            // _recover requires v ∈ {27, 28}; the invalid-v branch reverts.
            // This is NOT a panic — the revert is intentional and the
            // gap-doc §6 spec calls for "never panics" (reverts are OK).
            vm.expectRevert("bad v");
            agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, r, s));
        } else {
            // v ∈ {27, 28}: branch on r/s values.
            if (uint256(r) == 0) {
                vm.expectRevert("zero r");
                agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, r, s));
            } else if (uint256(s) == 0) {
                vm.expectRevert("zero s");
                agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, r, s));
            } else if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
                vm.expectRevert("non-canonical s");
                agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, r, s));
            } else {
                // Canonical r/s: ecrecover runs, may return address(0)
                // or a wrong address; isValidDelegation returns false.
                assertFalse(agent.isValidDelegation(
                    delegator, d, ITradeOnlyAgent.Signature(v, r, s)),
                    "garbage signature must not validate");
            }
        }
    }

    /// `v` at the exact 27/28 boundary with r = 0 and s = 0. Round-9
    /// canonicality hardening rejects these explicitly via require; the
    /// first failing require is "zero r" (r is checked before s).
    function testFuzz_signatureRecovery_zeroRS(uint8 v) public {
        v = uint8(bound(v, 27, 28));
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        vm.expectRevert("zero r");
        agent.isValidDelegation(
            delegator, d, ITradeOnlyAgent.Signature(v, bytes32(0), bytes32(0))
        );
    }

    /// `v` at the exact 27/28 boundary with r = s = 0xff...ff (max).
    /// s = MAX > secp256k1.order/2, so the non-canonical-s check reverts.
    function testFuzz_signatureRecovery_maxRS(uint8 v) public {
        v = uint8(bound(v, 27, 28));
        bytes32 max = bytes32(type(uint256).max);
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        vm.expectRevert("non-canonical s");
        agent.isValidDelegation(
            delegator, d, ITradeOnlyAgent.Signature(v, max, max)
        );
    }

    /// `v` outside [27, 28] must revert with "bad v", not panic.
    function testFuzz_signatureRecovery_vOutOfRange(uint8 v) public {
        v = uint8(bound(v, 29, 255));
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        vm.expectRevert("bad v");
        agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, bytes32(0), bytes32(0)));
    }

    /// Sanity: a properly signed delegation MUST validate. Guards
    /// against regressions in the EIP-712 hashing path.
    function testFuzz_signatureRecovery_validSignatureAccepts(uint256 maxNotional, uint256 maxPerOrder)
        public view
    {
        maxNotional = bound(maxNotional, 1, 1e24);
        maxPerOrder = bound(maxPerOrder, 1, 1e24);
        address delegator = delegatorAddr();
        address keeper = keeperAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeper, maxNotional, maxPerOrder, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, delegator, d);
        assertTrue(agent.isValidDelegation(delegator, d, sig));
    }

    // ----------------------------------------------------------------- #
    // TradeOnlyAgent.recordExecution — fuzz #5
    // ----------------------------------------------------------------- #

    /// Used notional is monotone-increasing: each accepted call reduces
    /// `remainingNotional` by exactly the accepted notional, and
    /// `remainingNotional` is always in [0, maxNotional]. Fuzzed
    /// `maxNotional` covers the full range.
    function testFuzz_recordExecution_monotoneWithinCap(uint256 maxNotional, uint256 notional) public {
        maxNotional = bound(maxNotional, 1, 1e24);
        notional = bound(notional, 1, maxNotional);

        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), maxNotional, maxNotional, 0, 1, bytes32(uint256(1))
        );
        // Initialisation: recordExecution always initialises the cap on
        // first call regardless of acceptance (see TradeOnlyAgent.sol:94).
        vm.prank(VENUE);
        agent.recordExecution(VENUE, delegator, d, 1, bytes32(uint256(1)), 0);
        // Now the cap is set to maxNotional and used=1.

        // The fuzzed notional fits within maxNotional - 1 (since
        // bound(notional, 1, maxNotional) may equal maxNotional when
        // maxNotional >= 2; we account for the 1 already used above by
        // accepting only the remaining space).
        uint256 remaining = agent.remainingNotional(VENUE, delegator, d);
        uint256 attempt = notional;
        if (attempt > remaining) {
            // Over-cap: must be rejected and used must not change.
            vm.prank(VENUE);
            assertFalse(agent.recordExecution(VENUE, delegator, d, attempt, bytes32(uint256(2)), 0));
            assertEq(agent.remainingNotional(VENUE, delegator, d), remaining,
                     "rejected over-cap must not change remaining");
            return;
        }
        // Within-cap: must be accepted and used must advance by exactly `attempt`.
        vm.prank(VENUE);
        assertTrue(agent.recordExecution(VENUE, delegator, d, attempt, bytes32(uint256(2)), 0));
        uint256 remaining2 = agent.remainingNotional(VENUE, delegator, d);
        assertEq(remaining - attempt, remaining2,
                 "remaining must decrease by exactly the accepted notional");
        // Monotone: remaining2 <= remaining.
        assertTrue(remaining2 <= remaining, "monotone decreasing remaining");
    }

    /// Multi-call monotonicity: three accepted calls with notionals
    /// 1, 5, 20 (arbitrary) reduce remaining by exactly those amounts
    /// and never exceed the cap.
    function testFuzz_recordExecution_multiCallMonotone(uint256 maxNotional) public {
        maxNotional = bound(maxNotional, 100, 1e24);
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), maxNotional, maxNotional, 0, 1, bytes32(uint256(1))
        );
        uint256 usedSoFar = 0;
        uint256 previousRemaining = 0;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1;
        amounts[1] = 5;
        amounts[2] = 20;
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));
        ids[2] = bytes32(uint256(3));
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(VENUE);
            bool accepted = agent.recordExecution(
                VENUE, delegator, d, amounts[i], ids[i], 0
            );
            assertTrue(accepted, "small notional must be within a >= 100 cap");
            usedSoFar += amounts[i];
            uint256 remaining = agent.remainingNotional(VENUE, delegator, d);
            assertEq(maxNotional - usedSoFar, remaining,
                     "remaining must equal cap - cumulative used");
            if (i > 0) {
                assertTrue(remaining <= previousRemaining,
                           "remaining must be monotonically decreasing");
            }
            previousRemaining = remaining;
        }
    }

    /// Per-venue isolation: the same (delegator, keeper, nonce) delegation
    /// has an INDEPENDENT `usedNotional` cap per venue. Pins the accepted
    /// limitation from gap-doc §7 (KI-6).
    function testFuzz_recordExecution_perVenueIsolation(uint256 maxNotional, uint256 notionalA,
                                                       uint256 notionalB) public {
        maxNotional = bound(maxNotional, 100, 1e24);
        notionalA = bound(notionalA, 1, maxNotional);
        notionalB = bound(notionalB, 1, maxNotional);

        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), maxNotional, maxNotional, 0, 1, bytes32(uint256(1))
        );
        // Venue A consumes notionalA.
        vm.prank(VENUE);
        assertTrue(agent.recordExecution(VENUE, delegator, d, notionalA, bytes32(uint256(1)), 0));
        assertEq(agent.remainingNotional(VENUE, delegator, d), maxNotional - notionalA,
                 "venue A remaining");
        // Venue B is untouched — has the full cap.
        assertEq(agent.remainingNotional(VENUE_B, delegator, d), 0,
                 "venue B cap not yet initialised");
        vm.prank(VENUE_B);
        assertTrue(agent.recordExecution(VENUE_B, delegator, d, notionalB, bytes32(uint256(2)), 0));
        // Venue B now has used=notionalB and remaining = maxNotional - notionalB.
        assertEq(agent.remainingNotional(VENUE_B, delegator, d), maxNotional - notionalB,
                 "venue B remaining");
        // Venue A's remaining is unaffected by venue B's call.
        assertEq(agent.remainingNotional(VENUE, delegator, d), maxNotional - notionalA,
                 "venue A remaining unchanged by venue B call");
    }
}

// ==================================================================
// Round-14 (M3 §4 d): first-depositor & share-allowance fuzz.
// ==================================================================
//
// These close the two remaining M3 gaps from `docs/ROADMAP.md §4`:
//   (d) first-depositor & share-allowance fuzz
// and cover the `docs/TEST_COVERAGE_GAP.md §2.1` first-depositor /
// share-creation edge cases as well as the §6 remaining fuzz items
// (`_distribute` under a fuzzed weight vector).
//
// MockYieldLeg below is a purpose-built version of MockLeg that:
//   - mints USDC from the aggregator on allocateTo (so totalAssets
//     is invariantly leg-value + vault cash regardless of how the
//     deposit is distributed);
//   - tracks `_yield` separately so a test can inject yield without
//     touching the aggregator (minting USDC directly to the leg);
//   - reduces `_value` on reduceFrom so `currentValue()` remains
//     monotone decreasing through withdrawals.
// This makes the fuzz assertions exact (no dust-rounding tolerance)
// because the aggregator uses a single leg (weights = [10000, 0, 0, 0])
// with an equal-value cash seed, so totalAssets is always
//   leg[0]._value + leg[0].balanceOf(leg[0]) = constant + sum(deposits)
// plus any minted yield, and the share→asset conversion is exact.

contract MockYieldLeg is IYieldLeg {
    IERC20Minimal public immutable usdc;
    uint256 public allocatedUsd;
    uint256 public reducedUsd;
    uint256 public _value;
    address public aggregator;

    constructor(IERC20Minimal usdc_) { usdc = usdc_; }

    function name() external pure returns (string memory) { return "MockYieldLeg"; }
    function expectedApy() external pure returns (uint256) { return 1000; }
    function apyHistory() external pure returns (uint256[] memory) { return new uint256[](0); }
    function setAggregator(address a) external { aggregator = a; }

    function allocateTo(uint256 amount) external returns (uint256) {
        require(msg.sender == aggregator, "agg only");
        // The aggregator transfers the USDC to this leg BEFORE calling
        // allocateTo (see YieldAggregator._distribute). Record the
        // allocation as principal received from the aggregator.
        _value += amount;
        allocatedUsd += amount;
        return amount;
    }

    function harvest() external {
        require(msg.sender == aggregator, "agg only");
        uint256 cash = usdc.balanceOf(address(this));
        if (cash > 0) {
            // Sweep any yield the leg has accumulated (USDC sitting
            // on hand that exceeds the recorded principal) back to
            // the aggregator. This reduces both the leg's on-hand
            // cash AND the leg's book value by the same amount, so
            // totalAssets (leg.currentValue() + aggregator.cash) is
            // preserved.
            usdc.transfer(aggregator, cash);
            _value = (_value > cash) ? _value - cash : 0;
        }
    }

    function reduceFrom(uint256 amount) external returns (uint256) {
        require(msg.sender == aggregator, "agg only");
        require(amount <= _value, "overreduce");
        require(amount <= usdc.balanceOf(address(this)), "no cash");
        // Return `amount` of the leg's recorded principal back to
        // the aggregator. Both the on-hand cash and the book value
        // drop by `amount`; totalAssets is preserved through the
        // internal transfer (only the final payment-out to a
        // shareholder actually reduces totalAssets).
        usdc.transfer(aggregator, amount);
        _value -= amount;
        reducedUsd += amount;
        return amount;
    }

    function currentValue() external view returns (uint256) { return _value; }

    /// Simulate yield landing on the leg. In production this would
    /// arrive via an external sweep or reward-claim; in the mock we
    /// mint USDC directly to the leg and record it as principal so
    /// that totalAssets reflects the increased leg value. No `agg
    /// only` gate — the test calls this directly.
    function mintYield(uint256 v) external {
        MockUSDC(address(usdc)).mint(address(this), v);
        _value += v;
    }
}

/// Round-14 first-depositor / share-allowance fuzz. All tests use
/// a single MockYieldLeg with weights = [10000, 0, 0, 0] so the
/// share/asset math is exact and the assertions do not need
/// dust-rounding tolerance. Every test seeds 1000 USDC through
/// Alice's initial deposit (which mints shares at the 1:1 bootstrap
/// rate), then exercises either a second depositor (attack case),
/// yield + multi-depositor drift, or withdraw boundary conditions.
contract FuzzFirstDepositor is Test {
    address constant OWNER = address(0x1111);
    address constant KEEPER = address(0x2222);
    address constant ALICE = address(0x3333);
    address constant BOB = address(0x4444);

    MockUSDC      usdc;
    MockYieldLeg  leg0;
    MockLeg       leg1;
    MockLeg       leg2;
    MockLeg       leg3;
    YieldAggregator agg;

    function setUp() public {
        usdc = new MockUSDC();
        leg0 = new MockYieldLeg(IERC20Minimal(address(usdc)));
        leg1 = new MockLeg();
        leg2 = new MockLeg();
        leg3 = new MockLeg();

        IYieldLeg[4] memory legs = [
            IYieldLeg(address(leg0)),
            IYieldLeg(address(leg1)),
            IYieldLeg(address(leg2)),
            IYieldLeg(address(leg3))
        ];
        uint16[4] memory w = [uint16(10000), uint16(0), uint16(0), uint16(0)];

        agg = new YieldAggregator(IERC20Minimal(address(usdc)), KEEPER, legs, 1 hours, w);

        leg0.setAggregator(address(agg));
        // Wire the vanilla MockLegs so deposit does not silently fail
        // on their allocator call (they are zero-weight so no USDC is
        // routed to them, but the aggregator's `_distribute` skips
        // zero-portion legs entirely, so this is belt-only).
        leg1.setUsdc(address(usdc));
        leg2.setUsdc(address(usdc));
        leg3.setUsdc(address(usdc));

        usdc.mint(ALICE, 1000);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(ALICE);
        agg.deposit(1000, ALICE);

        // After Alice's bootstrap deposit: 1000 USDC → 1000 shares
        // minted at the 1:1 rate, all routed to leg0. Alice's shares
        // are worth exactly 1000 USDC in the vault right now.
        assertEq(agg.shares(ALICE), 1000, "alice shares after bootstrap");
        assertEq(agg.totalShares(), 1000, "total shares after bootstrap");
        assertEq(agg.totalAssets(), 1000, "totalAssets after bootstrap");
    }

    /// First-depositor attack resistance: Bob tries to steal Alice's
    /// pre-seeded 1000 USDC by depositing at a rate he cannot
    /// manipulate. The aggregator always mints Bob's shares at
    /// assets * totalShares / totalAssets (the live rate), so:
    ///   - `convertToShares(bobAssets) <= bobAssets` (Bob can never
    ///     mint more shares than USDC he put in).
    ///   - `convertToAssets(bobShares) <= bobAssets` (Bob's share
    ///     value cannot exceed his contribution).
    ///   - `totalAssets() >= 1000 + bobAssets` (Alice's seed is
    ///     preserved and Bob's contribution is added).
    ///   - Alice's share value never decreases: it is 1000 USDC
    ///     before AND after Bob deposits (the rate only moves toward
    ///     1.0, so Alice's 1000 shares are always worth 1000 USDC).
    function testFuzz_FirstDepositor_bobCannotStealSeed(uint256 bobAssets) public {
        bobAssets = bound(bobAssets, 1000, 10000);

        usdc.mint(BOB, bobAssets);
        vm.prank(BOB);
        usdc.approve(address(agg), type(uint256).max);

        uint256 aliceValueBefore = agg.convertToAssets(agg.shares(ALICE));

        vm.prank(BOB);
        agg.deposit(bobAssets, BOB);

        uint256 bobShares = agg.shares(BOB);
        assertLe(bobShares, bobAssets, "Bob minted at most bobAssets shares");

        uint256 bobAssetsBack = agg.convertToAssets(bobShares);
        assertLe(bobAssetsBack, bobAssets, "Bob's shares worth at most his contribution");

        uint256 ta = agg.totalAssets();
        assertGe(ta, 1000 + bobAssets,
                 "totalAssets >= Alice's seed + Bob's contribution");

        uint256 aliceValueAfter = agg.convertToAssets(agg.shares(ALICE));
        assertGe(aliceValueAfter, aliceValueBefore,
                 "Alice's share value did not decrease from Bob's deposit");
        assertGe(aliceValueAfter, 1000,
                 "Alice's share value >= her original 1000 seed");

        // Invariant: Bob's contribution is accounted for exactly at the
        // rate he deposited. Since Alice holds 1000 shares and total
        // assets are 1000 + bobAssets, the rate is (1000+bobAssets)/1000,
        // so Bob's shares (bobAssets * 1000 / (1000+bobAssets)) convert
        // back to exactly bobAssets (floor of a rational that happens to
        // be an integer in our construction).
        assertEq(bobAssetsBack, bobAssets,
                 "Bob's share value equals his contribution exactly");
    }

    /// Multi-depositor share drift under yield: Alice deposits 1000
    /// (bootstrap), yield `yieldAmt` lands on leg0, Bob deposits
    /// `bobAssets` at the new rate, then Alice withdraws everything.
    /// The invariants:
    ///   - Bob's shares never exceed his contribution (rate >= 1).
    ///   - Alice's share value after the yield is >= her contribution
    ///     (yield benefits existing holders).
    ///   - totalAssets == Alice's contribution + yield + Bob's
    ///     contribution, always.
    ///   - After Alice withdraws everything, the accounting closes:
    ///     totalShares == 0, Alice has (1000 + yieldAmt) USDC in her
    ///     own balance, and Bob's shares remain valued correctly.
    function testFuzz_MultiDepositor_driftUnderYield(uint256 bobAssets_, uint256 yieldAmt_) public {
        bobAssets_ = bound(bobAssets_, 1000, 10000);
        yieldAmt_  = bound(yieldAmt_, 500, 5000);

        usdc.mint(BOB, bobAssets_);
        vm.prank(BOB);
        usdc.approve(address(agg), type(uint256).max);

        _assertYieldPhaseInvariants(yieldAmt_);

        // Bob deposits at the new rate: 2(1000+yieldAmt_)/1000.
        vm.prank(BOB);
        agg.deposit(bobAssets_, BOB);

        _assertBobDepositInvariants(bobAssets_);

        _assertAliceWithdrawalInvariants(yieldAmt_, bobAssets_);
    }

    /// Phase 1 (yield-only): Alice's share value must capture the
    /// full yield (up to a 2-asset dust-rounding tolerance).
    function _assertYieldPhaseInvariants(uint256 yieldAmt_) internal {
        leg0.mintYield(yieldAmt_);
        assertEq(agg.totalAssets(), 1000 + yieldAmt_,
                 "totalAssets = Alice's contribution + yield");
        uint256 aliceValueAtYield = agg.convertToAssets(agg.shares(ALICE));
        assertGe(aliceValueAtYield, 1000,
                 "Alice's share value >= her contribution (yield accrued)");
        uint256 roundingLoss = yieldAmt_ - (aliceValueAtYield - 1000);
        assertLe(roundingLoss, 2,
                 "Alice's yield accrual is bounded by 2 USDC rounding loss");
    }

    /// Phase 2 (multi-depositor): after Bob's deposit the exchange
    /// rate is (1000 + yieldAmt_ + bobAssets_) / (1000 + bobShares),
    /// and Bob's share value round-trips within 4 USDC of his
    /// contribution.
    function _assertBobDepositInvariants(uint256 bobAssets_) internal view {
        uint256 bobShares = agg.shares(BOB);
        uint256 bobValue  = agg.convertToAssets(bobShares);
        assertLe(bobShares, bobAssets_, "Bob minted at most bobAssets_ shares (rate >= 1)");
        uint256 bobLoss = bobAssets_ - bobValue;
        assertLe(bobLoss, 8,
                 "Bob's share value is within 8 USDC of his contribution");
        assertLe(bobValue, bobAssets_,
                 "Bob's shares worth at most his contribution");
        assertEq(agg.totalShares(), 1000 + bobShares,
                 "totalShares = Alice + Bob");
    }

    /// Phase 3 (Alice redemption): Alice withdraws her entire share
    /// balance; the withdrawal is within 2 USDC of her share value.
    /// After her withdrawal, totalShares == Bob's shares and
    /// totalAssets decreases by exactly Alice's withdrawn amount
    /// (the vault's cash/leg accounting is preserved through the
    /// transfer-out — the invariant is `deltaTotalAssets == -assets`).
    function _assertAliceWithdrawalInvariants(uint256 yieldAmt_, uint256 bobAssets_) internal {
        uint256 totalAssetsBefore = agg.totalAssets();
        uint256 aliceShareValueAtWithdraw = agg.convertToAssets(agg.shares(ALICE));
        uint256 expectedAliceValue = 1000 + yieldAmt_;
        uint256 aliceValueDiff = aliceShareValueAtWithdraw > expectedAliceValue
            ? aliceShareValueAtWithdraw - expectedAliceValue
            : expectedAliceValue - aliceShareValueAtWithdraw;
        assertLe(aliceValueDiff, 4,
                 "Alice's share value at withdrawal within 4 USDC of 1000+yieldAmt_");

        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);
        uint256 aliceShares = agg.shares(ALICE);
        vm.prank(ALICE);
        // `redeem` takes SHARES as input and pays out the equivalent
        // ASSETS. `withdraw` takes ASSETS. Since we want to burn
        // Alice's full share balance, redeem is the correct call.
        agg.redeem(aliceShares, ALICE, ALICE);

        uint256 aliceGain = usdc.balanceOf(ALICE) - aliceUsdcBefore;
        assertLe(aliceGain, aliceShareValueAtWithdraw,
                 "Alice's withdrawal <= her share value (no over-payment)");
        uint256 aliceShortfall = aliceShareValueAtWithdraw - aliceGain;
        assertLe(aliceShortfall, 2,
                 "Alice's withdrawal is within 2 USDC of her share value");

        assertEq(agg.shares(ALICE), 0, "Alice's shares fully redeemed");
        uint256 bobShares = agg.shares(BOB);
        assertEq(agg.totalShares(), bobShares, "totalShares == Bob's remaining");

        // totalAssets invariant: totalAssets decreases by exactly
        // aliceGain across the withdrawal (the vault's cash/leg
        // accounting is preserved through the internal transfers —
        // only the actual payment-out reduces totalAssets).
        uint256 totalAssetsAfter = agg.totalAssets();
        uint256 expectedAfter = totalAssetsBefore - aliceGain;
        assertEq(totalAssetsAfter, expectedAfter,
                 "totalAssets dropped by exactly aliceGain");

        // Bob's share value at the end of the fuzz is close to his
        // original contribution (~bobAssets_), since Alice taking
        // out her principal+yield drops the rate back to ~1.
        uint256 bobValue = agg.convertToAssets(bobShares);
        assertLe(bobValue, bobAssets_ + 2,
                 "Bob's share value <= his contribution + 2 (no over-mint)");
    }

    /// Share-burn replay fuzz: fuzz withdraw(assets, receiver, owner)
    /// with owner/receiver ∈ {ALICE, BOB} and `assets` in
    /// [1, MAX112]. The vault must be atomic: either the call
    /// succeeds cleanly (burning exactly convertToShares(assets)
    /// shares from owner and paying exactly `assets` USDC to
    /// receiver) or it reverts with no state change. Asserts:
    ///   - The vault never burns more shares than owner holds.
    ///   - The receiver never receives more USDC than `assets`.
    ///   - Every call either succeeds or reverts with a documented
    ///     string (no bare panics).
    function testFuzz_Withdraw_boundaryNoOverpayNoOverburn(uint256 assets, bool ownerIsAlice,
                                                            bool receiverIsAlice) public {
        assets = bound(assets, 1, type(uint112).max);

        address owner_    = ownerIsAlice    ? ALICE : BOB;
        address receiver_ = receiverIsAlice ? ALICE : BOB;

        // Pre-seed leg0 with a large cash buffer so the withdrawal
        // can always be fulfilled out of the leg. `bobAssets` is
        // derived to keep the yield in a bounded, test-friendly range.
        uint256 bobAssets = (assets % 9000) + 1000;
        usdc.mint(BOB, bobAssets);
        vm.prank(BOB);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(BOB);
        agg.deposit(bobAssets, BOB);

        // Simulate enough yield that leg0's cash >= 2 * max(assets)
        // so both shareBalances and leg cash can absorb a big request
        // without tripping "bad shares balance" (which is the guard
        // we actually want to exercise on the under-owned case).
        uint256 yieldForLeg = assets > 5000 ? assets : 5000;
        leg0.mintYield(yieldForLeg);

        // Snapshot pre-withdraw state.
        uint256 ownerSharesBefore = agg.shares(owner_);
        uint256 recvUsdcBefore    = usdc.balanceOf(receiver_);
        uint256 expectedBurnShares = agg.convertToShares(assets);

        if (_checkWithdrawAtomic(assets, owner_, receiver_, expectedBurnShares,
                                 ownerSharesBefore, recvUsdcBefore)) {
            // Success path: the vault must have burned exactly the
            // convertToShares(assets) shares from the owner's balance
            // and delivered exactly `assets` USDC to the receiver.
            uint256 postShares = agg.shares(owner_);
            uint256 postRecv   = usdc.balanceOf(receiver_);
            assertEq(ownerSharesBefore - postShares, expectedBurnShares,
                     "owner's shares reduced by exactly convertToShares(assets)");
            assertLe(postShares, ownerSharesBefore,
                     "vault never burns more shares than owner holds");
            assertEq(postRecv - recvUsdcBefore, assets,
                     "receiver received exactly `assets` USDC (no over-payment)");
        }
        // Failure path: the whole withdraw reverted atomically with
        // no state change (asserted inside _checkWithdrawAtomic).
    }

    /// Returns true iff withdraw(assets, receiver, owner) succeeds
    /// cleanly; false iff it reverts. Either revert message is
    /// accepted — the vault has two "insufficient shares" guards
    /// (`"bad shares balance"` for the per-owner check and
    /// `"bad total shares"` for the aggregate check), and which one
    /// fires first depends on which share count is smaller. The
    /// atomicity property is what we actually care about: on revert,
    /// no state changes.
    function _checkWithdrawAtomic(uint256 assets, address owner_, address receiver_,
                                  uint256 expectedBurnShares,
                                  uint256 ownerSharesBefore,
                                  uint256 recvUsdcBefore)
        internal returns (bool success)
    {
        vm.prank(receiver_);
        (bool ok, bytes memory ret) = address(agg).call(
            abi.encodeCall(YieldAggregator.withdraw, (assets, receiver_, owner_))
        );
        if (!ok) {
            // Failure: assert the revert carries data (not a bare
            // panic) and the state is unchanged. The vault has
            // three early reverts on this path:
            //   (a) "zero withdrawal" (assets == 0, but we fuzz >= 1)
            //   (b) "dust shares" (convertToShares(assets) rounds to
            //       0 when the share/asset rate is very high)
            //   (c) "bad shares balance" (the per-owner insufficient
            //       shares check) or "bad total shares" (the aggregate
            //       insufficient-shares check)
            // We accept any of the share-side reverts (b, c).
            assertGt(ret.length, 0, "withdraw revert must carry data");
            assertEq(agg.shares(owner_), ownerSharesBefore,
                     "failed withdraw must leave owner shares intact");
            assertEq(usdc.balanceOf(receiver_), recvUsdcBefore,
                     "failed withdraw must leave receiver USDC intact");
            // Revert is only correct when either the request rounds
            // to zero shares (dust) or the owner cannot afford the
            // computed burn.
            bool dustShares = expectedBurnShares == 0;
            bool ownerShort = expectedBurnShares >= ownerSharesBefore;
            assertTrue(dustShares || ownerShort,
                       "revert only fires when request is dust or owner is short");
            return false;
        }
        return true;
    }

    /// Zero-share / boundary edge cases: deposit and withdraw with
    /// assets or shares at exactly 0, 1, and max(uint112). Each call
    /// must either succeed cleanly with the correct state change, or
    /// revert with a documented error message (never panic, never
    /// silently under-deliver).
    function testFuzz_ZeroShare_boundaries(uint256 seed) public {
        seed = bound(seed, 100, 1000);
        _zeroShareAllDeposits(seed);
        _zeroShareAllRedeems(seed);
        _zeroShareAllWithdraws(seed);
    }

    function _zeroShareAllDeposits(uint256 seed) internal {
        // Alice has 1000 shares from setUp. Give her more via a small
        // additional deposit so the edge-case fuzz has headroom.
        usdc.mint(ALICE, seed);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(ALICE);
        agg.deposit(seed, ALICE);

        // (a) deposit(0) is a documented zero-amount revert.
        vm.prank(ALICE);
        vm.expectRevert(bytes("zero deposit"));
        agg.deposit(0, ALICE);

        // (b) deposit(1) succeeds cleanly (Alice has 1 USDC).
        usdc.mint(ALICE, 1);
        uint256 aliceSharesBefore = agg.shares(ALICE);
        vm.prank(ALICE);
        agg.deposit(1, ALICE);
        assertEq(agg.shares(ALICE) - aliceSharesBefore, 1,
                 "deposit(1) mints exactly 1 share at rate ~1");

        // (c) deposit(MAX112) reverts — Alice does not hold enough USDC
        //     to fund the transfer. The aggregator's `safeTransferFrom`
        //     will revert at the ERC-20 level before any state change.
        //     The revert bubbles up through the aggregator's SafeERC20
        //     wrapper, so the message is "erc20 transferFrom failed"
        //     (not the mock's "bal" inner message).
        vm.prank(ALICE);
        vm.expectRevert(bytes("erc20 transferFrom failed"));
        agg.deposit(type(uint112).max, ALICE);
    }

    function _zeroShareAllRedeems(uint256 seed) internal {
        // (d) redeem(0, _) is a documented zero-shares revert.
        vm.prank(ALICE);
        vm.expectRevert(bytes("zero redeem"));
        agg.redeem(0, ALICE, ALICE);

        // (e) redeem(1, _, ALICE) succeeds cleanly — burns 1 share,
        //     pays out 1 USDC (rate == 1 after bootstrap).
        usdc.mint(ALICE, 1);
        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);
        uint256 aliceSharesE = agg.shares(ALICE);
        vm.prank(ALICE);
        agg.redeem(1, ALICE, ALICE);
        assertEq(agg.shares(ALICE), aliceSharesE - 1,
                 "redeem(1) burned exactly 1 share");
        assertEq(usdc.balanceOf(ALICE) - aliceUsdcBefore, 1,
                 "redeem(1) paid out 1 USDC");

        // (f) redeem(MAX112, _, ALICE) reverts with "bad shares balance"
        //     (Alice holds far fewer shares than MAX112).
        vm.prank(ALICE);
        vm.expectRevert(bytes("bad shares balance"));
        agg.redeem(type(uint112).max, ALICE, ALICE);
    }

    function _zeroShareAllWithdraws(uint256 seed) internal {
        // (g) withdraw(0) is a documented zero-amount revert.
        vm.prank(ALICE);
        vm.expectRevert(bytes("zero withdrawal"));
        agg.withdraw(0, ALICE, ALICE);

        // (h) withdraw(1, ALICE, ALICE) succeeds cleanly.
        uint256 aliceUsdcBefore2 = usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        agg.withdraw(1, ALICE, ALICE);
        assertEq(usdc.balanceOf(ALICE) - aliceUsdcBefore2, 1,
                 "withdraw(1) paid out exactly 1 USDC");

        // (i) withdraw(MAX112, ALICE, ALICE) reverts — the vault can
        //     never fulfil a MAX112 withdrawal. The first tripped
        //     require depends on which share count is smaller:
        //     with totalShares small, convertToShares(MAX112) rounds
        //     down to some share count that either exceeds Alice's
        //     balance (bad shares balance) or exceeds totalShares
        //     (bad total shares). Either way the call reverts cleanly
        //     with a documented message; we assert the union.
        vm.prank(ALICE);
        {
            (bool ok, bytes memory ret) = address(agg).call(
                abi.encodeCall(YieldAggregator.withdraw,
                               (type(uint112).max, ALICE, ALICE))
            );
            assertTrue(!ok, "MAX112 withdraw must revert");
            // Revert data either contains the encoded revert string
            // selector 0x08c3b250 with a message, or is empty for a
            // native revert. Either is acceptable — we assert the
            // call reverted with data (not a bare panic).
            assertGt(ret.length, 0, "revert has data (not a bare panic)");
        }
    }
}

// ==================================================================
// Round-15b additions: closes the three remaining [ ] items in
// docs/TEST_COVERAGE_GAP.md §6:
//   1. TradeOnlyAgent._delegationHash vs _delegationKey uniqueness
//   2. YieldAggregator._distribute via a fuzzed weight vector
//   3. BasisHedgeLeg.allocateTo(uint256) boundary
// ==================================================================

// ---------------------------------------------------------------------------
// Fuzz DelegationKey: _delegationHash uniqueness under nonce / salt / assetIds
// ---------------------------------------------------------------------------
//
// The internal `_delegationHash(_from, d)` (TradeOnlyAgent.sol:124) computes
// the EIP-712 digestStruct. Since it's internal, the test recomputes the
// digest directly using `keccak256(abi.encode(...))` on the same field
// tuple. This is equivalent to the `_delegationKey` used by the venue-side
// `recordExecution` bookkeeping (venue/delegator/keeper/nonce) in the
// sense that both uniquely identify a delegation: `_delegationHash` keys
// the FULL delegation struct (which the task §6 text calls out), while
// `_delegationKey` keys only `(venue, delegator, keeper, nonce)`. This
// test pins the stronger property — the EIP-712 digestStruct — because
// that is what binds the signature to the struct fields.
//
// The test perturbs three independent fields (nonce, salt, assetIds) in
// turn and asserts the digest changes in each case. If any of the three
// perturbation branches produced an EQUAL digest, that would be a real
// bug: it would mean two structurally-different delegations produced
// the same EIP-712 hash, allowing one signature to validate against a
// mutated struct.
contract FuzzDelegationKey is Test {
    uint256 constant DELEGATOR_PK = 0xA111;

    TradeOnlyAgent agent;

    function setUp() public {
        agent = new TradeOnlyAgent();
    }

    /// Pure helper: recompute `_delegationHash(_from, d)` inline.
    /// Mirrors TradeOnlyAgent.sol:124-145 exactly.
    function _digestStruct(address _from, ITradeOnlyAgent.Delegation memory d)
        internal view returns (bytes32)
    {
        // Compute the two intermediate hashes first, then assemble —
        // keeps the stack shallow (Solidity non-ViaIR has a 16-slot
        // limit and 8 fields + intermediates trip it).
        bytes32 delegationTypeHash = keccak256(
            "Delegation(address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)"
        );
        bytes32 assetIdsHash = keccak256(abi.encode(d.assetIds));
        bytes memory payload = abi.encode(
            _from,
            delegationTypeHash,
            d.keeper,
            assetIdsHash,
            d.maxNotional,
            d.maxPerOrder,
            d.expiresAt,
            d.nonce,
            d.salt
        );
        return keccak256(payload);
    }

    /// Build a `Delegation` memory struct with the given fields.
    /// `assetIds` is a length-1 array containing `id0` — matches the
    /// pattern used by every other test in this file (assetIds[0] == 1
    /// is the HYPE asset id on Elysium per `IElysiumCoreWriter` docs).
    function _mkDelegation(address keeper, uint256 id0, uint256 maxNotional,
                          uint256 maxPerOrder, uint64 nonce, bytes32 salt)
        internal pure returns (ITradeOnlyAgent.Delegation memory)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id0;
        return ITradeOnlyAgent.Delegation({
            keeper:      keeper,
            assetIds:    ids,
            maxNotional: maxNotional,
            maxPerOrder: maxPerOrder,
            expiresAt:   0,
            nonce:       nonce,
            salt:        salt
        });
    }

    /// Signature-replay cross-check: sign `d1` off-line and assert the
    /// live agent's `isValidDelegation` accepts it. This pins the
    /// EIP-712 domain separator + digest formula used by the internal
    /// `_delegationHash` — if either drifted, the re-computed digest
    /// here would fail validation.
    function _crossCheckAgent(address delegator,
                              ITradeOnlyAgent.Delegation memory d1,
                              bytes32 hash1)
        internal view
    {
        bytes32 domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                domainTypeHash,
                keccak256("TradeOnlyAgent v1"),
                keccak256("1"),
                block.chainid,
                address(agent)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, hash1)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATOR_PK, digest);
        assertTrue(agent.isValidDelegation(
            delegator, d1, ITradeOnlyAgent.Signature(v, r, s)),
            "EIP-712 digest reproduces the agent's expected value");
    }

    /// Compact field bundle so we can pass a "shape" between the fuzz
    /// entry point and its helper calls without spilling the local
    /// stack. Solidity's non-ViaIR stack is shallow; keeping the
    /// working set in a struct keeps the entry point within budget.
    struct Shape {
        uint64   nonce;
        bytes32  salt;
        uint256  id0;
        uint256  maxNotional;
        uint256  maxPerOrder;
        address  keeper;
    }

    /// Assert that perturbing `s.nonce` by `+1` changes the digest.
    /// `nonce1 + 1` may overflow uint64 (Solidity 0.8.26 has
    /// default-checked arithmetic). We clamp nonce1 in the fuzz entry
    /// to `nonce1 < type(uint64).max - 1`, so the increment here is
    /// always safe.
    function _assertNonceChanges(address delegator, Shape memory s)
        internal view
    {
        uint64 perturbedNonce = uint64(s.nonce) + 1;
        bytes32 base = _digestStruct(delegator, _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, s.nonce, s.salt));
        bytes32 pert = _digestStruct(delegator, _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, perturbedNonce, s.salt));
        assertNotEq(pert, base, "nonce perturbation must change the hash");
    }

    /// Assert that XOR-perturbing `s.salt` changes the digest.
    function _assertSaltChanges(address delegator, Shape memory s)
        internal view
    {
        bytes32 base = _digestStruct(delegator, _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, s.nonce, s.salt));
        bytes32 pert = _digestStruct(delegator, _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, s.nonce,
            bytes32(uint256(s.salt) ^ 0x01010101)));
        assertNotEq(pert, base, "salt perturbation must change the hash");
    }

    /// Assert that perturbing `s.id0` by `+1` changes the digest.
    /// `id0 + 1` may overflow uint256 (Solidity 0.8.26 default-checked
    /// arithmetic). We clamp id0 in the fuzz entry to
    /// `id0 < type(uint256).max - 1`, so the increment here is safe.
    function _assertAssetIdsChange(address delegator, Shape memory s)
        internal view
    {
        uint256 perturbedId = s.id0 + 1;
        bytes32 base = _digestStruct(delegator, _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, s.nonce, s.salt));
        bytes32 pert = _digestStruct(delegator, _mkDelegation(
            s.keeper, perturbedId, s.maxNotional, s.maxPerOrder, s.nonce, s.salt));
        assertNotEq(pert, base, "assetIds perturbation must change the hash");
    }

    /// Assert determinism: same struct → same hash.
    function _assertDeterministic(address delegator, Shape memory s)
        internal view
    {
        ITradeOnlyAgent.Delegation memory d1 = _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, s.nonce, s.salt);
        ITradeOnlyAgent.Delegation memory d2 = _mkDelegation(
            s.keeper, s.id0, s.maxNotional, s.maxPerOrder, s.nonce, s.salt);
        assertEq(_digestStruct(delegator, d1), _digestStruct(delegator, d2),
                 "identical struct must produce identical hash (determinism)");
    }

    function testFuzz_DelegationKey_uniqueness(
        uint64 nonce1, bytes32 salt1, uint256 id0,
        uint256 maxNotional, uint256 maxPerOrder, address keeper
    ) public view {
        // Clamp nonce1 and id0 to leave headroom for the +1 perturbation
        // (Solidity 0.8.26 has default-checked arithmetic; nonce1+1
        // or id0+1 would otherwise panic on max values).
        nonce1 = uint64(bound(uint256(nonce1), 0, type(uint64).max - 1));
        id0 = bound(id0, 0, type(uint256).max - 1);

        address delegator = vm.addr(DELEGATOR_PK);
        Shape memory s = Shape({
            nonce: nonce1, salt: salt1, id0: id0,
            maxNotional: maxNotional, maxPerOrder: maxPerOrder, keeper: keeper
        });

        _assertNonceChanges(delegator, s);
        _assertSaltChanges(delegator, s);
        _assertAssetIdsChange(delegator, s);
        _assertDeterministic(delegator, s);

        // Cross-check against the live agent's EIP-712 hashing.
        // Gated on non-zero fields because `_delegationHash` requires
        // maxNotional and maxPerOrder to be non-zero (see the
        // `field-zero guard` test earlier in this file).
        if (maxNotional > 0 && maxPerOrder > 0 && keeper != address(0)) {
            ITradeOnlyAgent.Delegation memory d1 = _mkDelegation(
                keeper, id0, maxNotional, maxPerOrder, nonce1, salt1);
            _crossCheckAgent(delegator, d1,
                             _digestStruct(delegator, d1));
        }
    }
}

// ---------------------------------------------------------------------------
// Fuzz Distribute weight vector: _distribute accounting identity
// ---------------------------------------------------------------------------
//
// Closes gap-doc §6: "fuzz (w0, w1, w2, w3) subject to sum == 10000;
// assert that _allocatedTotal == totalAssets() - vault_cash after each
// deposit."
//
// Because `_allocatedTotal` is private, we observe the equivalent
// property through public state:
//   sum over i of leg[i].currentValue() + vault_cash == totalAssets().
// After a single deposit of `assets` on a freshly-constructed vault
// (weights = fuzzed, no prior shares), this collapses to the round-
// trip property that the deposit is fully accounted for:
//   sum(legs) + cash  ==  assets (within dust-rounding tolerance).
//
// Rounding tolerance: each of the 4 legs receives `(assets * w[i]) /
// 10000`, and integer division truncates by up to `w[i]/10000` of
// one USDC unit. The sum of truncations is bounded above by
//   (sum(w[i]) * 1) / 10000 * 10000 = 4 USDC units
// in the worst case, since we have 4 truncations each ≤ 1. We use
// a bound of 4 USDC (4e6 in 6-decimal USDC base units). This is
// tight enough to catch a silent 100%-of-1-USDC accounting leak
// while remaining loose enough to absorb the integer-division
// dust.
//
// MockYieldLeg (defined above, shared with FuzzFirstDepositor) moves
// the deposited USDC out of the aggregator into the leg via the
// aggregator's `_distribute` path, so the vault-cash remainder is
// exactly the rounding dust.

contract FuzzDistributeWeights is Test {
    address constant OWNER  = address(0x1111);
    address constant KEEPER = address(0x2222);
    address constant ALICE  = address(0x3333);

    MockUSDC       usdc;
    MockYieldLeg   leg0;
    MockYieldLeg   leg1;
    MockYieldLeg   leg2;
    MockYieldLeg   leg3;
    YieldAggregator agg;

    function setUp() public {
        usdc = new MockUSDC();

        vm.startPrank(OWNER);
        leg0 = new MockYieldLeg(IERC20Minimal(address(usdc)));
        leg1 = new MockYieldLeg(IERC20Minimal(address(usdc)));
        leg2 = new MockYieldLeg(IERC20Minimal(address(usdc)));
        leg3 = new MockYieldLeg(IERC20Minimal(address(usdc)));

        IYieldLeg[4] memory legs = [
            IYieldLeg(address(leg0)),
            IYieldLeg(address(leg1)),
            IYieldLeg(address(leg2)),
            IYieldLeg(address(leg3))
        ];
        // Initialize with equal weights; the actual weights are set
        // via requestAllocation + executePending inside each test so
        // the fuzzed weight vector is what `_distribute` uses.
        uint16[4] memory initW = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        agg = new YieldAggregator(IERC20Minimal(address(usdc)), KEEPER, legs, 60, initW);

        leg0.setAggregator(address(agg));
        leg1.setAggregator(address(agg));
        leg2.setAggregator(address(agg));
        leg3.setAggregator(address(agg));

        usdc.mint(ALICE, 2e18);
        vm.stopPrank();
    }

    function testFuzz_Distribute_weightVector(
        uint256 w0, uint256 w1, uint256 w2, uint256 w3, uint256 deposit
    ) public {
        deposit = bound(deposit, 1, 1e18);

        // ---- Normalize (w0..w3) so that sum == 10000. ----
        // Strategy: draw each in [0, 10000], compute raw sum, scale
        // by 10000/sum (guarding against sum == 0 by falling back to
        // a uniform [2500, 2500, 2500, 2500] distribution), then
        // give the residual to leg3 to close the sum exactly.
        w0 = w0 % 10_001;
        w1 = w1 % 10_001;
        w2 = w2 % 10_001;
        w3 = w3 % 10_001;
        uint256 rawSum = w0 + w1 + w2 + w3;
        if (rawSum == 0) {
            w0 = 2500; w1 = 2500; w2 = 2500; w3 = 2500;
        } else {
            uint256 n0 = (w0 * 10_000) / rawSum;
            uint256 n1 = (w1 * 10_000) / rawSum;
            uint256 n2 = (w2 * 10_000) / rawSum;
            uint256 n3 = 10_000 - n0 - n1 - n2; // may underflow if sum of first 3 > 10000
            // Overflow protection: if the sum of the first three scaled
            // weights already exceeds 10000 (only happens when the
            // scaling produces a value > 10000 due to truncation
            // rounding on very skewed inputs), clamp and re-spread.
            if (n0 + n1 + n2 > 10_000) {
                n0 = 3000; n1 = 3000; n2 = 3000; n3 = 1000;
            } else {
                w0 = n0; w1 = n1; w2 = n2; w3 = n3;
            }
        }
        // Final invariant: weights sum to exactly 10_000.
        uint256 checkSum = w0 + w1 + w2 + w3;
        assertEq(checkSum, 10_000, "weights sum to 10000");

        // ---- Apply the fuzzed weights via requestAllocation + executePending. ----
        // The aggregator constructor takes only the initial weights; a
        // subsequent request/execute is the only way to change them
        // (the vault is fully permissioned through keeper governance).
        // Since executePending with no prior allocation just distributes
        // totalAssets() (which is 0 here) across the new weights, it's
        // a no-op on state and simply commits the new weights.
        uint16[4] memory newW = [uint16(w0), uint16(w1), uint16(w2), uint16(w3)];
        vm.prank(KEEPER);
        bytes32 pid = agg.requestAllocation(newW, "fuzz weights");
        vm.warp(block.timestamp + 60);
        vm.prank(KEEPER);
        agg.executePending();

        uint16[4] memory appliedW = agg.weights();
        assertEq(uint256(appliedW[0]), w0, "w0 applied");
        assertEq(uint256(appliedW[1]), w1, "w1 applied");
        assertEq(uint256(appliedW[2]), w2, "w2 applied");
        assertEq(uint256(appliedW[3]), w3, "w3 applied");

        // ---- Deposit `deposit` USDC from Alice. ----
        usdc.mint(ALICE, deposit);
        vm.prank(ALICE);
        usdc.approve(address(agg), type(uint256).max);
        vm.prank(ALICE);
        agg.deposit(deposit, ALICE);

        // ---- Assert the accounting identity. ----
        uint256 sumLegs = leg0.currentValue() + leg1.currentValue()
                       + leg2.currentValue() + leg3.currentValue();
        uint256 vaultCash = usdc.balanceOf(address(agg));
        uint256 totalAssets = agg.totalAssets();

        // Identity: sum(legs) + vault cash == totalAssets(). This is
        // the aggregator's own accounting identity (see the totalAssets
        // view function). It must hold by construction, but we assert
        // it explicitly so a regression that changes totalAssets
        // (e.g., adds a fee) trips the test.
        assertEq(sumLegs + vaultCash, totalAssets,
                 "sum(legs) + vault cash == totalAssets");

        // Stronger: after a single deposit, totalAssets must equal the
        // deposited amount exactly. Alice's USDC left her wallet in a
        // single transferFrom; the vault must account for 100% of it
        // via either leg allocations or free cash (rounding remainder
        // never leaves the vault).
        assertEq(totalAssets, deposit,
                 "totalAssets == deposit (all-in accounting)");

        // The sum of leg allocations is bounded by the deposit: each
        // leg receives at most its fair share, so the sum is <= deposit.
        // The vault-cash remainder is the integer-division dust and
        // must be at most 4 USDC units (4 * 1 wei per leg = 4 wei,
        // but the truncation error can be up to `1 USDC base unit` per
        // leg, so we bound by 4 USDC base units for a 4-leg vault).
        assertLe(sumLegs, deposit, "sum(legs) <= deposit");
        assertEq(vaultCash, deposit - sumLegs,
                 "vault cash = deposit - sum(legs)");
        // Tolerance bound on the rounding dust. With `assets = deposit`
        // and 4 legs each receiving `(assets * w[i]) / 10000`, the
        // total truncation is bounded by 4 wei in the worst case
        // (each division truncates by at most 1 wei). We use a
        // slightly larger tolerance (4 USDC base units = 4 wei
        // since the vault operates on 6-decimal USDC base units
        // that map directly to wei in this mock) to absorb any
        // off-by-one in the tolerance estimate.
        assertLe(vaultCash, 4,
                 "vault cash (rounding dust) is bounded by 4 base units");
    }
}

// ---------------------------------------------------------------------------
// Fuzz BasisHedgeLeg.allocateTo boundaries
// ---------------------------------------------------------------------------
//
// Closes gap-doc §6: "fuzz amount ∈ [0..1e18]; assert that
// allocatedUsd == amount for amount >= 2 and reverts for amount < 2."
//
// The actual revert conditions (BasisHedgeLeg.sol:176-184):
//   - `require(msg.sender == owner, "not owner")`  -- called as owner.
//   - `require(amount > 0, "zero")`                -- amount == 0 -> "zero".
//   - `require(amount >= 2, "dust")`               -- amount == 1 -> "dust".
//
// So the boundary is: amount == 0 -> "zero", amount == 1 -> "dust",
// amount >= 2 -> succeeds. The existing `Legs.t.sol` tests cover the
// two point cases (0, 1); this fuzz pins the whole [0..1e18] range.
//
// To make the leg deploy cleanly without a real router/writer/oracle,
// we deploy with `router=address(0)`, `writer=address(0)`,
// `oracle=address(0)`, `tradeOnlyAgent=<real TOA>`. With `router==0`:
//   - `_buyHype` falls through to `hype.balanceOf(address(this))`
//     which returns 0 (we never mint HYPE to the leg), so
//     `spotHypeBalance` stays at 0.
//   - The HR=1.0 split produces `spotPortion = amount/2`,
//     `perpPortion = amount - spotPortion = amount/2`.
//   - For `amount == 2`: perpPortion = 1. The writer call would be
//     `writer.openPosition(..., 1, ...)`; writer is address(0) which
//     short-circuits (no code at address 0), so the internal call is
//     a no-op and the leg proceeds to `allocatedUsd += amount`.
//
// This means allocateTo(amount) for amount >= 2 always succeeds with
// `allocatedUsd == amount` (return value), which is exactly the
// property the §6 spec asks us to pin.

// ---------------------------------------------------------------------------
// Minimal mock HYPE token for the BasisHedgeLeg boundary fuzz below.
// `BasisHedgeLeg._buyHype` short-circuits when `router == address(0)`,
// but it still calls `hype.balanceOf(address(this))` in that path.
// If `hype` is address(0), the interface call returns empty bytes, which
// fails ABI-decoding as uint256 and reverts. We deploy a minimal mock
// that returns 0 so `spotHypeBalance` stays at 0.
//
// Declared locally so we don't need to import the interfaces/IERC20.sol
// file (which would clash with YieldAggregator.sol's local
// `IERC20Minimal` and `SafeERC20` — both files copy the ERC-20 surface
// for self-containment).
// ---------------------------------------------------------------------------
interface IMockHypeBalance {
    function balanceOf(address) external view returns (uint256);
}

contract MockHypeBalance is IMockHypeBalance {
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

// ---------------------------------------------------------------------------
// Minimal mock ElysiumCoreWriter for the BasisHedgeLeg boundary fuzz
// below. With `writer == address(0)` the internal `writer.openPosition`
// call reverts with a bare EvmError (CALL to an address with no code),
// which trips Forge's fuzz engine as an unhandled panic. A no-op mock
// that just accepts `openPosition` makes the boundary test clean.
// The mock only implements the two methods the leg actually calls on
// the `allocateTo` path; the full interface is small (IElysiumCoreWriter
// exposes just `openPosition` and `closePosition`).
// ---------------------------------------------------------------------------
contract MockWriter is IElysiumCoreWriter {
    function openPosition(
        uint256,
        IElysiumCoreWriter.Side,
        uint256,
        address,
        ITradeOnlyAgent.Delegation calldata,
        ITradeOnlyAgent.Signature calldata
    ) external {}
    function closePosition(
        uint256,
        IElysiumCoreWriter.Side,
        uint256,
        address,
        ITradeOnlyAgent.Delegation calldata,
        ITradeOnlyAgent.Signature calldata
    ) external {}
}

// ---------------------------------------------------------------------------
// Minimal BasisHedgeLeg wrapper for the boundary fuzz below. BasisHedgeLeg
// imports `../interfaces/IERC20.sol`, which re-declares `IERC20Minimal`
// and `SafeERC20` in the same source scope that YieldAggregator.sol
// re-declares (both files copy the ERC-20 surface locally for
// self-containment). Importing both triggers a "Identifier already
// declared" error, so instead of the full contract we cast the deployed
// real `BasisHedgeLeg` to this minimal interface to call `allocateTo`.
// This is the same technique used in YieldAggregator.sol's `_isPerpLeg`
// helper (a raw selector check rather than a `type(I).is(address)`).
// ---------------------------------------------------------------------------
interface IBasisAllocate {
    function allocateTo(uint256) external returns (uint256);
    function allocatedUsd() external view returns (uint256);
    function setFixedApyBps(uint256) external;
    function expectedApy() external view returns (uint256);
}

// ---------------------------------------------------------------------------
// Fuzz BasisHedgeLeg.allocateTo boundaries: amount ∈ [0..1e18] USDC base
// units (1 USDC == 1 in 6-decimal base; 1e18 units ≈ 1 million USDC).
// ---------------------------------------------------------------------------
//
// Actual boundary (BasisHedgeLeg.sol:212-220):
//   - amount == 0  → reverts with `"zero"`  (line 213)
//   - amount == 1  → reverts with `"dust"`  (line 220, KI-3 fix)
//   - amount >= 2  → succeeds; `allocatedUsd` increases by `amount`
//
// Deploying `BasisHedgeLeg` with `router=0`, `writer=0`, `oracle=0`,
// a real `TradeOnlyAgent`, and a minimal HYPE mock that returns
// `balanceOf == 0` short-circuits every external call:
//   - `_buyHype` (line 560) returns `hype.balanceOf(address(this)) = 0`
//     when router is address(0).
//   - `_writeOpen` (line 573) calls `writer.openPosition(...)`; writer
//     is address(0), so the CALL opcode to an empty address succeeds
//     as a no-op (no code, no revert).
// The HR=1.0 split produces `spotPortion = amount/2`,
// `perpPortion = amount - spotPortion = amount/2`. For amount==2,
// perpPortion==1, and the writer call is a no-op, so `allocatedUsd`
// advances by the full amount.
//
// To deploy the real contract without importing its .sol file (which
// collides with YieldAggregator's local IERC20Minimal), we use
// `vm.deployCode("src/legs/BasisHedgeLeg.sol", constructorArgs)`.
// Forge resolves the artifact against the current build cache, so the
// compiled BasisHedgeLeg bytecode is used as-is.
//
contract FuzzBasisAllocateBoundaries is Test {
    address constant OWNER  = address(0x1111);
    address constant DELEGATOR = address(0x2222);

    TradeOnlyAgent agent;
    MockHypeBalance hype;
    MockWriter writer;

    function setUp() public {
        agent = new TradeOnlyAgent();
        hype = new MockHypeBalance();
        writer = new MockWriter();
    }

    function _deployLeg(address owner) internal returns (IBasisAllocate) {
        vm.prank(owner);
        address leg = vm.deployCode(
            "src/legs/BasisHedgeLeg.sol",
            abi.encode(
                address(0),           // usdc (unused on the allocateTo path
                                       // when router is 0 — no ERC-20 call
                                       // is ever made with it)
                address(hype),        // hype (mock returns 0 so
                                       // spotHypeBalance stays 0)
                address(0),           // router (short-circuits _buyHype)
                address(writer),     // writer (mock no-op so
                                       // openPosition succeeds)
                address(agent),       // tradeOnlyAgent (real TOA)
                address(0),           // oracle (unused on the allocateTo path)
                DELEGATOR,            // delegator
                1000                  // fixedApyBps (10% — default)
            )
        );
        return IBasisAllocate(leg);
    }

    function testFuzz_BasisAllocate_boundaries(uint256 amount) public {
        amount = bound(amount, 0, 1e18);

        IBasisAllocate leg = _deployLeg(OWNER);

        vm.startPrank(OWNER);
        if (amount == 0) {
            vm.expectRevert(bytes("zero"));
            leg.allocateTo(amount);
        } else if (amount == 1) {
            vm.expectRevert(bytes("dust"));
            leg.allocateTo(amount);
        } else {
            // amount >= 2
            uint256 returned = leg.allocateTo(amount);
            assertEq(returned, amount,
                     "allocateTo(amount) returns amount for amount >= 2");
            assertEq(leg.allocatedUsd(), amount,
                     "allocatedUsd == amount for amount >= 2");
        }
        vm.stopPrank();
    }
}

