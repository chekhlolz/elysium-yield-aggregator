// SPDX-License-Identifier: MIT

// All tests in this file are deterministic integration tests; the
// file has no fuzz targets, so the fuzz.runs setting is irrelevant.

// ---------------------------------------------------------------------------
// Round-14: ElysiumCoreWriter integration coverage (M3 last-mile).
//
// The IElysiumCoreWriter interface today only declares `openPosition` and
// `closePosition`. The doc comment on the interface explicitly says the
// real contract will add order book, liquidation, and margin primitives
// in the months that follow mainnet. Legs route every perp operation
// through this writer, but the current MockWriter in Legs.t.sol only
// records invocations — it does not exercise venue-side validation or
// the extended surface the production predeploy will expose.
//
// This file ships:
//   1. `FullElysiumCoreWriterMock` — a stateful mock that implements
//      the full surface a real ElysiumCoreWriter will have: open,
//      close, getOpenOrders, getPosition, liquidate, setMargin, and
//      getPositionState. Venue-side validation is real (signature
//      sanity, expiry, per-order cap, per-venue notional cap, replay).
//   2. `ElysiumCoreWriterIntegrationTest` — 18 integration tests
//      covering open/close round-trip, liquidation, margin, verifier
//      path (real vs fallback signatures), expired delegations,
//      replay, and cross-test integration with `PerpFundingLeg` and
//      `BasisHedgeLeg`.
//
// Cross-references:
//   - IElysiumCoreWriter doc: "order book, liquidation, and margin
//     primitives in the months that follow mainnet" (see
//     solidity/src/interfaces/IElysiumCoreWriter.sol).
//   - AGGREGATOR_SPEC.md §2.3: "ElysiumCoreWriter fails mid-flight →
//     Reconciler task compares intended vs executed".
//   - Design doc: DESIGN_KI2_SUBMITINTENT.md §4 (venue verifies sig,
//     aggregator verifies only cap math).
// ---------------------------------------------------------------------------

pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/interfaces/IElysiumCoreWriter.sol";
import "../src/interfaces/ITradeOnlyAgent.sol";
import "../src/interfaces/IERC20.sol";
import "../src/interfaces/IERC20Router.sol";
import "../src/interfaces/IPriceOracle.sol";
import "../src/interfaces/IFundingSource.sol";
import "../src/legs/PerpFundingLeg.sol";
import "../src/legs/BasisHedgeLeg.sol";

// ---------------------------------------------------------------------------
// Shared mocks (local to this file — the test is self-contained and must
// NOT depend on Legs.t.sol because that file is finalized).
// ---------------------------------------------------------------------------

contract MockUSDC2 is IERC20Minimal {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }
    function approve(address to, uint256 v) external override returns (bool) {
        allowance[msg.sender][to] = v; return true;
    }
    function transfer(address to, uint256 v) external override returns (bool) {
        require(balanceOf[msg.sender] >= v, "bal");
        balanceOf[msg.sender] -= v; balanceOf[to] += v; return true;
    }
    function transferFrom(address from, address to, uint256 v)
        external override returns (bool)
    {
        require(balanceOf[from] >= v, "bal");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= v, "allow");
            allowance[from][msg.sender] = allowed - v;
        }
        balanceOf[from] -= v; balanceOf[to] += v; return true;
    }
}

contract MockHYPE2 is MockUSDC2 {}

contract MockPriceOracle2 is IPriceOracle {
    uint256 public price = 2_000_000;
    function priceOf(string calldata) external view override returns (uint256) {
        return price;
    }
    function getApy(string calldata) external pure override returns (uint256) {
        return 1000;
    }
    function setPrice(uint256 p) external { price = p; }
}

contract MockRouter2 is IERC20Router {
    address public usdc;
    address public hype;
    uint256 public constant PRICE = 2_000_000;       // USDC per HYPE, 6-decimals
    uint256 public constant RATIO = 1_000_000;      // 1:1 rate for test rig

    constructor(address _usdc, address _hype) {
        usdc = _usdc; hype = _hype;
    }

    // USDC → HYPE at 1:1 (test-rig rate; the oracle is only used by
    // the leg's `currentValue()` view and does not affect swap amounts).
    function swapExactUSDCForToken(address tokenOut, uint256 amountIn)
        external override returns (uint256 outAmount)
    {
        MockUSDC2(usdc).transferFrom(msg.sender, address(this), amountIn);
        outAmount = amountIn; // 1:1
        MockHYPE2(tokenOut).mint(msg.sender, outAmount);
    }

    // HYPE → USDC at 1:1.
    function swapExactTokenForUSDC(address tokenIn, uint256 amountIn)
        external override returns (uint256 outAmount)
    {
        MockHYPE2(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        outAmount = amountIn; // 1:1
        MockUSDC2(usdc).mint(msg.sender, outAmount);
    }

    function getAmountOut(address, address, uint256 amountIn)
        external pure override returns (uint256 outAmount)
    {
        return amountIn;
    }
}

contract MockFundingSource2 is IFundingSource {
    int64 public fundingApy = 2000;
    function fundingRateBps(string calldata) external view override returns (int64) {
        return 20;
    }
    function fundingApyBps(string calldata) external view override returns (int64) {
        return fundingApy;
    }
}

// ---------------------------------------------------------------------------
// FullElysiumCoreWriterMock
//
// Implements the full surface a real ElysiumCoreWriter will expose
// beyond the current interface stub. Venue-side validation is real:
//   - Signature sanity (sig.v in {27, 28}; (r,s) not all-zero).
//   - Per-order cap (notional <= d.maxPerOrder).
//   - Per-venue notional cap (cumulative across calls).
//   - Expiry (d.expiresAt != 0 && block.timestamp > d.expiresAt → reject).
//   - Replay (keccak(keeper, nonce, salt) seen before → reject).
//
// The venue-side "position" is a flat sum of `openPosition` minus
// `closePosition` calls. `liquidate` sweeps a fixed fraction of the
// position and returns that as realized PnL to the liquidator.
// `setMargin` adjusts the position's margin level; the writer enforces
// a hard floor (`MIN_MARGIN = 10_000`).
// ---------------------------------------------------------------------------

contract FullElysiumCoreWriterMock is IElysiumCoreWriter {
    // ---- venue config ----
    uint256 public constant MIN_MARGIN = 10_000;   // in USD-6-decimals
    uint256 public constant LIQ_FRACTION_BPS = 1000; // 10% liquidated
    uint256 public constant MAX_VENUE_NOTIONAL = 100 * 1_000_000; // 100 USD

    // ---- state ----
    // Position keyed by (delegator, assetId). Notional is signed by
    // side: Long is positive, Short is negative. 6 decimals.
    mapping(bytes32 => Position) internal _positions;
    mapping(bytes32 => uint256) internal _margin;
    mapping(bytes32 => uint256) internal _cumulativeNotional;

    struct Position {
        int256  notional;       // +Long, -Short
        uint256 openCount;
        uint256 closeCount;
        uint256 margin;         // current margin on this position
        uint256 totalLiquidated;
    }

    // Invocations log for assertions.
    struct Call {
        bool    isOpen;
        uint256 assetId;
        uint256 notional;
        address delegator;
        address keeper;
        uint64  nonce;
        bytes32 sigHash;
    }
    Call[] public calls;

    // Replay ledger: composite key → seen once.
    mapping(bytes32 => bool) public seenIntents;

    // Toggle: reject the "fallback" zero signature (the phase-1
    // `_fallbackSig` placeholder with v=27, r=0, s=0). Real
    // production venues will reject this because the signature is
    // clearly not EIP-712 valid.
    bool public rejectZeroSig = true;

    // Toggle: simulate venue-side expiry enforcement (real writers
    // check block.timestamp against d.expiresAt).
    bool public enforceExpiry = true;

    event PositionOpened(address indexed delegator, address indexed keeper,
                         uint256 indexed assetId, uint256 notional, bool isLong);
    event PositionClosed(address indexed delegator, uint256 indexed assetId,
                         uint256 notional, int256 realizedPnl);
    event Liquidated(address indexed delegator, uint256 indexed assetId,
                     uint256 notionalLiquidated, int256 pnl);
    event MarginSet(address indexed delegator, uint256 indexed assetId,
                    uint256 newMargin);

    // ---- interface impl ----

    function openPosition(
        uint256 assetId, Side side, uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external override {
        _validateCommon(assetId, notional, delegator, d, sig);

        // Reject the legacy fallback sig when the venue policy is on.
        if (rejectZeroSig && _isZeroSig(sig)) {
            revert("writer: zero signature rejected (use submitIntent)");
        }

        // Per-venue cumulative cap.
        bytes32 venueKey = _venueKey(delegator, d.keeper, assetId);
        if (_cumulativeNotional[venueKey] + notional > MAX_VENUE_NOTIONAL) {
            revert("writer: venue notional cap exceeded");
        }
        _cumulativeNotional[venueKey] += notional;

        // Update position.
        bytes32 posKey = _posKey(delegator, assetId);
        Position storage p = _positions[posKey];
        int256 signed = (side == Side.Long) ? int256(int256(uint256(notional)))
                                             : -int256(int256(uint256(notional)));
        p.notional += signed;
        p.openCount += 1;

        // Record call.
        calls.push(Call({
            isOpen: true,
            assetId: assetId,
            notional: notional,
            delegator: delegator,
            keeper: d.keeper,
            nonce: d.nonce,
            sigHash: keccak256(abi.encode(sig.v, sig.r, sig.s))
        }));

        emit PositionOpened(delegator, d.keeper, assetId, notional,
                            side == Side.Long);
    }

    function closePosition(
        uint256 assetId, Side side, uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external override {
        _validateCommon(assetId, notional, delegator, d, sig);

        if (rejectZeroSig && _isZeroSig(sig)) {
            revert("writer: zero signature rejected (use submitIntent)");
        }

        bytes32 posKey = _posKey(delegator, assetId);
        Position storage p = _positions[posKey];
        // Closing a Short position (side == Short) reduces a negative
        // notional back toward zero. Closing a Long position reduces
        // a positive notional back toward zero.
        int256 signed = (side == Side.Long) ? -int256(int256(uint256(notional)))
                                             : int256(int256(uint256(notional)));
        int256 prior = p.notional;
        p.notional += signed;
        p.closeCount += 1;
        int256 realizedPnl = prior - p.notional; // 0 in our simplified mock

        calls.push(Call({
            isOpen: false,
            assetId: assetId,
            notional: notional,
            delegator: delegator,
            keeper: d.keeper,
            nonce: d.nonce,
            sigHash: keccak256(abi.encode(sig.v, sig.r, sig.s))
        }));

        emit PositionClosed(delegator, assetId, notional, realizedPnl);
    }

    // ---- order book ----

    /// Open orders for `delegator` are the still-live positions
    /// (|notional| > 0). Real venues expose order-book entries with
    /// more detail; this mock keeps the shape simple.
    function getOpenOrders(address delegator)
        external view returns (uint256[] memory assetIds,
                                int256[] memory notionals)
    {
        uint256 count = 0;
        for (uint256 a = 0; a < 8; a++) {
            bytes32 pk = _posKey(delegator, a);
            if (_positions[pk].notional != 0) count++;
        }
        assetIds = new uint256[](count);
        notionals = new int256[](count);
        uint256 i = 0;
        for (uint256 a = 0; a < 8; a++) {
            bytes32 pk = _posKey(delegator, a);
            int256 n = _positions[pk].notional;
            if (n != 0) {
                assetIds[i] = a;
                notionals[i] = n;
                i++;
            }
        }
    }

    // ---- liquidation ----

    /// Liquidate `funds` (USD-6-decimals) of the position. The
    /// liquidator sweeps 10% of the position's |notional| and
    /// realizes the (mocked) pnl.
    function liquidate(
        uint256 assetId,
        address delegator,
        uint256 funds
    ) external returns (int256 pnl) {
        bytes32 pk = _posKey(delegator, assetId);
        Position storage p = _positions[pk];
        require(p.notional != 0, "no position");
        require(funds > 0, "zero funds");

        // Liquidation sweeps 10% of |notional|, bounded by `funds`.
        uint256 absNotional = p.notional > 0 ? uint256(p.notional)
                                             : uint256(-p.notional);
        uint256 toClose = (absNotional * LIQ_FRACTION_BPS) / 10_000;
        if (toClose > funds) toClose = funds;
        if (toClose > absNotional) toClose = absNotional;

        // Realize (mock) pnl = 1% of the closed notional, in the
        // direction the liquidator wins. For a Short position being
        // liquidated the perp dropped, so the liquidator (Long)
        // wins; we record +pnl. For a Long being liquidated the perp
        // rose, so the liquidator (Short) wins; same +pnl sign.
        int256 realized = int256(toClose) * 100 / 10_000;
        p.notional = (p.notional > 0) ? int256(int256(p.notional) - int256(toClose))
                                       : int256(int256(p.notional) + int256(toClose));
        p.totalLiquidated += toClose;
        pnl = realized;
        emit Liquidated(delegator, assetId, toClose, realized);
    }

    // ---- margin ----

    /// Adjust margin on a position. The venue enforces MIN_MARGIN.
    function setMargin(
        uint256 assetId,
        address delegator,
        uint256 newMargin
    ) external {
        require(newMargin >= MIN_MARGIN, "writer: margin below floor");
        bytes32 pk = _posKey(delegator, assetId);
        Position storage p = _positions[pk];
        p.margin = newMargin;
        _margin[pk] = newMargin;
        emit MarginSet(delegator, assetId, newMargin);
    }

    // ---- state ----

    /// Get the live position + margin state for a (delegator, assetId).
    function getPositionState(
        uint256 assetId,
        address delegator
    ) external view returns (int256 notional, uint256 margin, uint256 totalLiquidated)
    {
        bytes32 pk = _posKey(delegator, assetId);
        Position storage p = _positions[pk];
        return (p.notional, p.margin, p.totalLiquidated);
    }

    function getPosition(
        uint256 assetId, address delegator
    ) external view returns (int256) {
        return _positions[_posKey(delegator, assetId)].notional;
    }

    function positionCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 i) external view returns (Call memory) {
        return calls[i];
    }

    function cumulativeNotionalFor(address delegator, address keeper,
                                    uint256 assetId)
        external view returns (uint256)
    {
        return _cumulativeNotional[_venueKey(delegator, keeper, assetId)];
    }

    function isRejectZeroSig() external view returns (bool) {
        return rejectZeroSig;
    }

    function setRejectZeroSig(bool b) external { rejectZeroSig = b; }
    function setEnforceExpiry(bool b) external { enforceExpiry = b; }

    // ---- validation helpers ----

    function _validateCommon(
        uint256 assetId,
        uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) internal {
        require(sig.v == 27 || sig.v == 28, "writer: bad v");
        require(notional <= d.maxPerOrder, "writer: per-order cap");
        require(d.keeper != address(0), "writer: zero keeper");
        require(delegator != address(0), "writer: zero delegator");
        require(assetId != 0, "writer: zero assetId");
        // Replay: composite key must be unique.
        bytes32 replayKey = keccak256(abi.encode(d.keeper, d.nonce, d.salt));
        require(!seenIntents[replayKey], "writer: intent already used");
        seenIntents[replayKey] = true;
        // Expiry: enforce only when the venue policy says so AND the
        // delegation has a real expiry (expiresAt != 0).
        if (enforceExpiry && d.expiresAt != 0 &&
            uint256(block.timestamp) > uint256(d.expiresAt)) {
            revert("writer: delegation expired");
        }
    }

    function _isZeroSig(ITradeOnlyAgent.Signature calldata sig)
        internal pure returns (bool)
    {
        return sig.r == bytes32(0) && sig.s == bytes32(0);
    }

    function _posKey(address delegator, uint256 assetId)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(delegator, assetId));
    }

    function _venueKey(address delegator, address keeper, uint256 assetId)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(delegator, keeper, assetId));
    }
}

// ---------------------------------------------------------------------------
// A minimal ITradeOnlyAgent mock for direct writer calls. Same as
// MockTradeOnlyAgent in Legs.t.sol — duplicated so this file is
// self-contained and does not depend on a finalized test file.
// ---------------------------------------------------------------------------

contract MockTOA2 is ITradeOnlyAgent {
    bool public acceptSig = true;
    function isValidDelegation(
        address, ITradeOnlyAgent.Delegation calldata,
        ITradeOnlyAgent.Signature calldata
    ) external view override returns (bool) { return acceptSig; }
    function setAcceptSig(bool b) external { acceptSig = b; }
    function revoke(address) external override {}
    function isRevoked(address) external view override returns (bool) {
        return false;
    }
}

// ---------------------------------------------------------------------------
// ElysiumCoreWriterIntegrationTest
//
// 18 tests covering the writer's full surface.
// ---------------------------------------------------------------------------

contract ElysiumCoreWriterIntegrationTest is Test {
    address constant OWNER      = address(0x1111);
    address constant ALICE      = address(0x2222);
    address constant BOB        = address(0x3333);
    address constant LIQUIDATOR = address(0x4444);
    uint256 constant USD_1    = 1 * 1_000_000;
    uint256 constant USD_5    = 5 * 1_000_000;
    uint256 constant USD_10   = 10 * 1_000_000;
    uint256 constant USD_50   = 50 * 1_000_000;
    uint256 constant USD_100  = 100 * 1_000_000;
    uint256 constant HYPE_ASSET_ID = 1;

    FullElysiumCoreWriterMock writer;
    MockTOA2 toa;
    MockUSDC2 usdc;
    MockHYPE2 hype;
    MockPriceOracle2 oracle;
    MockFundingSource2 funding;
    MockRouter2 router;

    function setUp() public {
        writer  = new FullElysiumCoreWriterMock();
        toa     = new MockTOA2();
        usdc    = new MockUSDC2();
        hype    = new MockHYPE2();
        oracle  = new MockPriceOracle2();
        funding = new MockFundingSource2();
        router  = new MockRouter2(address(usdc), address(hype));
        usdc.mint(address(this), USD_100 * 100);
    }

    // ---- helpers ----

    function _delegation(address keeper, uint256 maxPerOrder,
                         uint64 nonce, uint64 expiresAt)
        internal pure returns (ITradeOnlyAgent.Delegation memory d)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = HYPE_ASSET_ID;
        d = ITradeOnlyAgent.Delegation({
            keeper:      keeper,
            assetIds:    ids,
            maxNotional: maxPerOrder,
            maxPerOrder: maxPerOrder,
            expiresAt:   expiresAt,
            nonce:       nonce,
            salt:        bytes32(uint256(nonce))
        });
    }

    function _goodSig() internal pure returns (ITradeOnlyAgent.Signature memory) {
        return ITradeOnlyAgent.Signature({
            v: 27,
            r: bytes32(uint256(0xA0B0C0)),
            s: bytes32(uint256(0xD0E0F0))
        });
    }

    function _zeroSig() internal pure returns (ITradeOnlyAgent.Signature memory) {
        return ITradeOnlyAgent.Signature({
            v: 27, r: bytes32(0), s: bytes32(0)
        });
    }

    // ---- TESTS ----

    // 1. Basic open short.
    function test_OpenShort_recordsPositionAndCall() public {
        vm.prank(BOB);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_50, BOB, _delegation(ALICE, USD_50, 1, 0), _goodSig()
        );
        assertEq(writer.positionCount(), 1, "1 call recorded");
        int256 pos = writer.getPosition(HYPE_ASSET_ID, BOB);
        assertEq(int256(pos), -int256(USD_50), "short 50 USD recorded");
        FullElysiumCoreWriterMock.Call memory c = writer.getCall(0);
        assertTrue(c.isOpen, "call is open");
        assertEq(c.delegator, BOB);
        assertEq(c.assetId, HYPE_ASSET_ID);
    }

    // 2. Basic open long.
    function test_OpenLong_recordsPositivePosition() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Long,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        assertEq(writer.getPosition(HYPE_ASSET_ID, ALICE), int256(USD_10));
    }

    // 3. Close reduces position back toward zero.
    function test_CloseShort_reducesPosition() public {
        vm.prank(BOB);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, BOB, _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        vm.prank(BOB);
        writer.closePosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, BOB, _delegation(ALICE, USD_10, 2, 0), _goodSig()
        );
        assertEq(writer.getPosition(HYPE_ASSET_ID, BOB), 0, "position closed");
        assertEq(writer.positionCount(), 2, "open + close = 2 calls");
    }

    // 4. Full open + close round-trip with distinct nonces (no replay).
    function test_FullRoundTrip_openAndCloseDistinctNonces() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Long,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        vm.prank(ALICE);
        writer.closePosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Long,
            USD_10, ALICE, _delegation(ALICE, USD_10, 2, 0), _goodSig()
        );
        FullElysiumCoreWriterMock.Call memory c1 = writer.getCall(0);
        FullElysiumCoreWriterMock.Call memory c2 = writer.getCall(1);
        assertTrue(c1.isOpen && !c2.isOpen);
        assertEq(writer.getPosition(HYPE_ASSET_ID, ALICE), 0);
    }

    // 5. Verifier path: writer rejects zero signature (fallback sig).
    function test_VerifierPath_rejectsZeroSig() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: zero signature rejected (use submitIntent)"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), _zeroSig()
        );
        assertEq(writer.positionCount(), 0, "no call after rejection");
    }

    // 6. Verifier path: writer accepts a real signature.
    function test_VerifierPath_acceptsRealSig() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        FullElysiumCoreWriterMock.Call memory c = writer.getCall(0);
        bytes32 expected = keccak256(abi.encode(27, bytes32(uint256(0xA0B0C0)),
                                                 bytes32(uint256(0xD0E0F0))));
        assertEq(c.sigHash, expected, "sig recorded");
    }

    // 7. Expired delegation rejected by the writer.
    function test_Expiry_rejectsExpiredDelegation() public {
        // Forge's default block.timestamp is 0; warp to a real wall-clock
        // so `block.timestamp - 10` does not underflow.
        vm.warp(1_700_000_000);
        // Expires 10 seconds in the past (relative to warped timestamp).
        uint64 pastExpiry = uint64(block.timestamp - 10);
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: delegation expired"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE,
            _delegation(ALICE, USD_10, 1, pastExpiry), _goodSig()
        );
        assertEq(writer.positionCount(), 0, "no call after expiry rejection");
    }

    // 8. Never-expires (expiresAt=0) accepted — sentinel means "skip".
    function test_Expiry_neverExpiresAccepted() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        assertEq(writer.positionCount(), 1);
    }

    // 9. Replay: same (keeper, nonce, salt) rejected on second use.
    function test_Replay_sameDelegationRejectedTwice() public {
        ITradeOnlyAgent.Delegation memory d =
            _delegation(ALICE, USD_10, 1, 0);
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, d, _goodSig()
        );
        // Second call with the SAME delegation — must revert.
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: intent already used"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, d, _goodSig()
        );
        assertEq(writer.positionCount(), 1, "only 1 call recorded");
    }

    // 10. Per-order cap enforced: notional > maxPerOrder → revert.
    function test_PerOrderCap_revertsOverCap() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: per-order cap"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(ALICE, USD_5, 1, 0), _goodSig()
        );
        assertEq(writer.positionCount(), 0);
    }

    // 11. Per-venue notional cap: cumulative notional across calls
    //     across venues. After USD_50 + USD_50, trying USD_10 more
    //     pushes cumulative to USD_110 > MAX_VENUE_NOTIONAL (100 USD).
    function test_VenueNotionalCap_cumulativeAcrossCalls() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_50, ALICE, _delegation(ALICE, USD_100, 1, 0), _goodSig()
        );
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_50, ALICE, _delegation(ALICE, USD_100, 2, 0), _goodSig()
        );
        // cumulative is now exactly at the cap. One more USD_10 → 110 USD.
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: venue notional cap exceeded"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(ALICE, USD_100, 3, 0), _goodSig()
        );
        uint256 cum = writer.cumulativeNotionalFor(ALICE, ALICE, HYPE_ASSET_ID);
        assertEq(cum, USD_100, "cumulative notional = 100 USD (at cap)");
        assertEq(writer.positionCount(), 2, "2 successful opens");
    }

    // 12. Liquidation sweeps 10% of position and returns pnl.
    function test_Liquidate_sweepsTenPercentAndRealizesPnl() public {
        vm.prank(BOB);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_100, BOB, _delegation(ALICE, USD_100, 1, 0), _goodSig()
        );
        int256 pnl = writer.liquidate{gas: 1_000_000}(
            HYPE_ASSET_ID, BOB, USD_100
        );
        // 10% of 100 USD = 10 USD liquidated; pnl = 1% of 10 USD = 0.1 USD
        // = 100_000 units.
        int256 remaining = writer.getPosition(HYPE_ASSET_ID, BOB);
        assertEq(remaining, -int256(USD_100 - USD_10),
                 "90% of position remains");
        // pnl is signed to favor the liquidator (positive).
        assertTrue(pnl > 0, "liquidator wins pnl");
        assertEq(uint256(pnl), 100_000, "pnl = 0.1 USD");
    }

    // 13. Set margin: below floor → revert; at/above floor → ok.
    function test_SetMargin_revertsBelowFloor() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: margin below floor"));
        writer.setMargin(HYPE_ASSET_ID, ALICE, 9_999);
    }

    function test_SetMargin_acceptsAtFloor() public {
        writer.setMargin(HYPE_ASSET_ID, ALICE, writer.MIN_MARGIN());
        (, uint256 m,) = writer.getPositionState(HYPE_ASSET_ID, ALICE);
        assertEq(m, writer.MIN_MARGIN(), "margin set");
    }

    // 14. getPositionState returns the correct tuple.
    function test_GetPositionState_returnsLiveTuple() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Long,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        writer.setMargin(HYPE_ASSET_ID, ALICE, USD_5);
        (int256 n, uint256 m,) = writer.getPositionState(HYPE_ASSET_ID, ALICE);
        assertEq(n, int256(USD_10));
        assertEq(m, USD_5);
    }

    // 15. Zero keeper rejected.
    function test_ZeroKeeper_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: zero keeper"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(address(0), USD_10, 1, 0), _goodSig()
        );
    }

    // 16. Bad signature v (not 27/28) rejected.
    function test_BadSignatureV_reverts() public {
        ITradeOnlyAgent.Signature memory badSig = ITradeOnlyAgent.Signature({
            v: 42, r: bytes32(uint256(1)), s: bytes32(uint256(2))
        });
        vm.prank(ALICE);
        vm.expectRevert(bytes("writer: bad v"));
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE, _delegation(ALICE, USD_10, 1, 0), badSig
        );
    }

    // ---- Cross-test with PerpFundingLeg ----

    /// The perp leg's `submitIntent` forwards the real signature to
    /// the writer. The full mock writer accepts the real sig and
    /// records the position; then `writer.getPosition` sees the
    /// perp-short notional the leg intended.
    function test_CrossPerpFundingLeg_submitIntent_forwardsToFullWriter()
        public
    {
        vm.prank(OWNER);
        PerpFundingLeg leg = new PerpFundingLeg(
            address(usdc), address(hype), address(router),
            address(writer), address(toa), address(funding), address(oracle),
            ALICE, 1000
        );

        // Fund the leg so `allocateTo`-side router call can pay the
        // 50/50 spot split.
        usdc.mint(address(leg), USD_100);
        vm.prank(address(leg));
        usdc.approve(address(router), type(uint256).max);

        ITradeOnlyAgent.Delegation memory d =
            _delegation(address(leg), USD_100, 1, 0);
        ITradeOnlyAgent.Signature memory sig = _goodSig();

        vm.prank(OWNER);
        uint256 returned = leg.submitIntent(d, sig, USD_100);
        assertEq(returned, USD_100, "submitIntent returned the requested amt");

        // The writer saw the call. Perp portion = 50% of 100 = 50.
        assertEq(writer.positionCount(), 1, "1 writer call");
        FullElysiumCoreWriterMock.Call memory c = writer.getCall(0);
        assertEq(c.notional, 50 * 1_000_000, "perp portion = 50 USD");
        assertEq(c.assetId, HYPE_ASSET_ID);
        // Position is Short (leg opens short perp).
        int256 pos = writer.getPosition(HYPE_ASSET_ID, ALICE);
        assertEq(int256(pos), -int256(50 * 1_000_000), "short 50 USD on book");
    }

    /// Fallback signature (v=27, r=0, s=0) used by the legacy
    /// allocateTo path is REJECTED by a real venue (the mock).
    /// This documents that the round-7 KI-2 fix (submitIntent) is
    /// load-bearing: the fallback path cannot pass a production
    /// venue's signature check.
    function test_CrossPerpFundingLeg_fallbackSig_rejectedByRealVenue()
        public
    {
        vm.prank(OWNER);
        PerpFundingLeg leg = new PerpFundingLeg(
            address(usdc), address(hype), address(router),
            address(writer), address(toa), address(funding), address(oracle),
            ALICE, 1000
        );
        usdc.mint(address(leg), USD_100);
        vm.prank(address(leg));
        usdc.approve(address(router), type(uint256).max);

        // `allocateTo` uses `_fallbackSig()` (v=27, r=0, s=0). With
        // devFallbackEnabled = true (default in the constructor),
        // this is the phase-1 dev path. On a real venue that path
        // should revert because the signature is zero.
        vm.prank(OWNER);
        vm.expectRevert(bytes("writer: zero signature rejected (use submitIntent)"));
        leg.allocateTo(USD_100);

        assertEq(writer.positionCount(), 0, "no writer call recorded");
    }

    /// Cross-test with `BasisHedgeLeg.submitIntent`: the same
    /// pattern as the perp leg but on the basis leg. Confirms the
    /// venue sees the perp-short notional from the basis leg too.
    function test_CrossBasisHedgeLeg_submitIntent_forwardsToFullWriter()
        public
    {
        vm.prank(OWNER);
        BasisHedgeLeg leg = new BasisHedgeLeg(
            address(usdc), address(hype), address(router),
            address(writer), address(toa), address(oracle),
            ALICE, 1000
        );
        usdc.mint(address(leg), USD_100);
        vm.prank(address(leg));
        usdc.approve(address(router), type(uint256).max);

        ITradeOnlyAgent.Delegation memory d =
            _delegation(address(leg), USD_100, 1, 0);
        ITradeOnlyAgent.Signature memory sig = _goodSig();

        vm.prank(OWNER);
        uint256 returned = leg.submitIntent(d, sig, USD_100);
        assertEq(returned, USD_100);
        assertEq(writer.positionCount(), 1);
        FullElysiumCoreWriterMock.Call memory c = writer.getCall(0);
        assertEq(c.notional, 50 * 1_000_000, "basis leg opens 50 USD perp");
    }

    /// Production simulation: an expired delegation forwarded by a
    /// compromised keeper. Even if the leg's verifier accepts it
    /// (verifier-side bug), the venue-side expiry check must kill
    /// it at the writer.
    function test_ProductionSim_expiredDelegationRevertedAtWriter()
        public
    {
        vm.prank(OWNER);
        PerpFundingLeg leg = new PerpFundingLeg(
            address(usdc), address(hype), address(router),
            address(writer), address(toa), address(funding), address(oracle),
            ALICE, 1000
        );
        usdc.mint(address(leg), USD_100);
        vm.prank(address(leg));
        usdc.approve(address(router), type(uint256).max);

        // Warp so `block.timestamp - 60` does not underflow on Forge
        // (default block.timestamp = 0).
        vm.warp(1_700_000_000);
        uint64 past = uint64(block.timestamp - 60);
        ITradeOnlyAgent.Delegation memory d =
            _delegation(address(leg), USD_100, 1, past);
        ITradeOnlyAgent.Signature memory sig = _goodSig();

        // The leg-side verifier accepts (we have acceptSig = true),
        // but the writer-side expiry check must fire. The expectRevert
        // bubbles the writer's revert string back to the leg.
        vm.prank(OWNER);
        vm.expectRevert(bytes("writer: delegation expired"));
        leg.submitIntent(d, sig, USD_100);
        assertEq(writer.positionCount(), 0);
    }

    /// Full end-to-end production simulation: submitIntent opens,
    /// then setMargin adjusts the position, then liquidate sweeps
    /// part of it. Everything goes through the full mock, not the
    /// recording-only MockWriter in Legs.t.sol.
    function test_ProductionSim_openMarginLiquidate_roundTrip()
        public
    {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_100, ALICE,
            _delegation(ALICE, USD_100, 1, 0), _goodSig()
        );

        writer.setMargin(HYPE_ASSET_ID, ALICE, USD_10);

        int256 pnl = writer.liquidate{gas: 1_000_000}(
            HYPE_ASSET_ID, ALICE, USD_100
        );

        // Position went from -100 to -90 (10% swept).
        int256 n = writer.getPosition(HYPE_ASSET_ID, ALICE);
        assertEq(n, -int256(90 * 1_000_000));

        // Margin is still set on the position.
        (, uint256 m,) = writer.getPositionState(HYPE_ASSET_ID, ALICE);
        assertEq(m, USD_10);

        // Liquidator realized positive pnl.
        assertTrue(pnl > 0);

        // The full flow left 1 open + 1 liquidate in the venue's
        // state (liquidate is not recorded in calls[], only the
        // open/close calls are).
        assertEq(writer.positionCount(), 1);
    }

    /// getOpenOrders returns the still-live positions for a
    /// delegator. With two positions open on different assetIds,
    /// the order book must reflect both.
    function test_GetOpenOrders_returnsBothPositions() public {
        vm.prank(ALICE);
        writer.openPosition(
            HYPE_ASSET_ID, IElysiumCoreWriter.Side.Short,
            USD_10, ALICE,
            _delegation(ALICE, USD_10, 1, 0), _goodSig()
        );
        vm.prank(ALICE);
        writer.openPosition(
            2, IElysiumCoreWriter.Side.Long,
            USD_10, ALICE,
            _delegation(ALICE, USD_10, 2, 0), _goodSig()
        );
        (uint256[] memory assetIds, int256[] memory notionals) =
            writer.getOpenOrders(ALICE);
        assertEq(assetIds.length, 2, "2 open positions");
        int256 sum = notionals[0] + notionals[1];
        assertEq(sum, 0, "short 10 + long 10 = 0 net");
    }
}
