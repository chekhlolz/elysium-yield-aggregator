// SPDX-License-Identifier: MIT
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
    /// For v ∈ [29, 30] the contract's `_recover` requires v ∈ {27, 28}
    /// and reverts with "bad v"; for v ∈ {27, 28} with extreme r/s,
    /// `ecrecover` returns address(0) or a wrong address, so
    /// `isValidDelegation` returns false. Both behaviours are acceptable
    /// — we assert "no panic" by checking one of those two.
    function testFuzz_signatureRecovery_neverPanics(uint8 v, bytes32 r, bytes32 s) public {
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        if (v >= 29) {
            // _recover requires v ∈ {27, 28}; the invalid-v branch reverts.
            // This is NOT a panic — the revert is intentional and the
            // gap-doc §6 spec calls for "never panics" (reverts are OK).
            vm.expectRevert("bad v");
            agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, r, s));
        } else if (v < 27) {
            vm.expectRevert("bad v");
            agent.isValidDelegation(delegator, d, ITradeOnlyAgent.Signature(v, r, s));
        } else {
            // v ∈ {27, 28}: ecrecover runs, may return address(0) or a
            // wrong address; isValidDelegation returns false (no panic).
            assertFalse(agent.isValidDelegation(
                delegator, d, ITradeOnlyAgent.Signature(v, r, s)),
                "garbage signature must not validate");
        }
    }

    /// `v` at the exact 27/28 boundary with r = 0 and s = 0 (illegal
    /// signature parameters). `ecrecover` returns address(0) for r=0 or
    /// s=0, so `isValidDelegation` returns false. No panic.
    function testFuzz_signatureRecovery_zeroRS(uint8 v) public {
        v = uint8(bound(v, 27, 28));
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        assertFalse(agent.isValidDelegation(
            delegator, d, ITradeOnlyAgent.Signature(v, bytes32(0), bytes32(0))),
            "r=0, s=0 must not validate");
    }

    /// `v` at the exact 27/28 boundary with r = s = 0xff...ff (max).
    /// ecrecover may return address(0) or a wrong address; the contract
    /// must not panic.
    function testFuzz_signatureRecovery_maxRS(uint8 v) public {
        v = uint8(bound(v, 27, 28));
        bytes32 max = bytes32(type(uint256).max);
        address delegator = delegatorAddr();
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            keeperAddr(), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        assertFalse(agent.isValidDelegation(
            delegator, d, ITradeOnlyAgent.Signature(v, max, max)),
            "r=MAX, s=MAX must not validate");
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
