// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/delegation/TradeOnlyAgent.sol";

contract TradeOnlyAgentTest is Test {
    uint256 constant DELEGATOR_PK = 0xA111;
    uint256 constant KEEPER_PK    = 0xB222;

    address DELEGATOR;
    address KEEPER;
    address constant VENUE   = address(0xC333);
    address constant KEEPER2 = address(0xD444);

    TradeOnlyAgent agent;

    function setUp() public {
        DELEGATOR = vm.addr(DELEGATOR_PK);
        KEEPER    = vm.addr(KEEPER_PK);
        agent = new TradeOnlyAgent();
    }

    function _mkDelegation(
        address keeper,
        uint256 maxNotional,
        uint256 maxPerOrder,
        uint64 expiresAt,
        uint64 nonce,
        bytes32 salt
    ) internal pure returns (ITradeOnlyAgent.Delegation memory) {
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

    function _mkEmptyDelegation() internal view returns (ITradeOnlyAgent.Delegation memory) {
        return ITradeOnlyAgent.Delegation({
            keeper: KEEPER,
            assetIds: new uint256[](0),
            maxNotional: 100,
            maxPerOrder: 50,
            expiresAt: 0,
            nonce: 1,
            salt: bytes32(0)
        });
    }

    function _sign(
        uint256 pk,
        address from,
        ITradeOnlyAgent.Delegation memory d
    ) internal view returns (ITradeOnlyAgent.Signature memory) {
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

    // ---- Construction & happy path ----

    function test_happyPath_validDelegationAccepted() public view {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertTrue(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_delegationWithExpiryNotYetExpired() public {
        vm.warp(1_000);
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, uint64(2_000), 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertTrue(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    // ---- FIX-7 (round-3 P1): expiresAt == 0 sentinel accepts "no expiry" ----

    function test_expiresAtZero_neverExpiresAccepts() public {
        // Simulate "current time is arbitrarily far in the future" —
        // expiresAt == 0 must still be valid.
        vm.warp(2_000_000_000);
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertTrue(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_expiresAtNonZero_expiresAfterTime() public {
        // Delegate with expiresAt=1000, warp past it — must be rejected.
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 1000, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        vm.warp(2000);
        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    // ---- Field-level guards ----

    function test_rejectsZeroKeeper() public view {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            address(0), 1000, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_rejectsZeroMaxNotional() public view {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 0, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_rejectsZeroMaxPerOrder() public view {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 0, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_rejectsWrongSigner() public view {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        // Sign with keeper's key — must be rejected because from=DELEGATOR.
        ITradeOnlyAgent.Signature memory sig = _sign(KEEPER_PK, DELEGATOR, d);
        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_rejectsTamperedSignature() public view {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        sig.r ^= bytes32(uint256(1));
        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    function test_rejectsBadV() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        sig.v = 200;
        // _recover has require(v==27||v==28) — expectRevert with any revert.
        vm.expectRevert();
        agent.isValidDelegation(DELEGATOR, d, sig);
    }

    // ---- Revoke ----

    function test_revoke_rejectsZeroKeeper() public {
        vm.prank(DELEGATOR);
        vm.expectRevert("zero keeper");
        agent.revoke(address(0));
    }

    function test_revoke_setsIsRevokedTrue() public {
        vm.prank(DELEGATOR);
        agent.revoke(KEEPER);
        vm.startPrank(DELEGATOR);
        assertTrue(agent.isRevoked(KEEPER));
        assertFalse(agent.isRevoked(KEEPER2));
        vm.stopPrank();
    }

    function test_revoke_invalidatesValidDelegation() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertTrue(agent.isValidDelegation(DELEGATOR, d, sig));

        vm.prank(DELEGATOR);
        agent.revoke(KEEPER);

        assertFalse(agent.isValidDelegation(DELEGATOR, d, sig));
    }

    // ---- recordExecution: FIX-14 (round-3 P1) per-venue notional cap ----

    function test_recordExecution_requiresVenueCaller() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        vm.prank(DELEGATOR);
        vm.expectRevert("not venue");
        agent.recordExecution(VENUE, DELEGATOR, d, 100, bytes32(uint256(1)), 0);
    }

    function test_recordExecution_venueCanRecordWithinCap() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        vm.prank(VENUE);
        bool accepted = agent.recordExecution(
            VENUE, DELEGATOR, d, 400, bytes32(uint256(1)), 0
        );
        assertTrue(accepted);
        // 600 notional remains.
        assertEq(agent.remainingNotional(VENUE, DELEGATOR, d), 600);
    }

    function test_recordExecution_venueCapEnforced() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        // Use 900 of 1000, then another 200 must fail (900+200 > 1000).
        vm.prank(VENUE);
        assertTrue(agent.recordExecution(VENUE, DELEGATOR, d, 900, bytes32(uint256(1)), 0));
        vm.prank(VENUE);
        assertFalse(agent.recordExecution(VENUE, DELEGATOR, d, 200, bytes32(uint256(1)), 0));
        assertEq(agent.remainingNotional(VENUE, DELEGATOR, d), 100);
    }

    function test_recordExecution_perVenueIsolation() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        // Venue A consumes 1000 (full cap). Venue B still has the full cap.
        address venueB = address(0xEE00);
        vm.prank(VENUE);
        assertTrue(agent.recordExecution(VENUE, DELEGATOR, d, 1000, bytes32(uint256(1)), 0));
        vm.prank(venueB);
        assertTrue(agent.recordExecution(venueB, DELEGATOR, d, 1000, bytes32(uint256(1)), 0));
        assertEq(agent.remainingNotional(VENUE, DELEGATOR, d), 0);
        assertEq(agent.remainingNotional(venueB, DELEGATOR, d), 0);
    }

    function test_recordExecution_firstExecutionSetsCap() public {
        ITradeOnlyAgent.Delegation memory d = _mkDelegation(
            KEEPER, 1000, 500, 0, 1, bytes32(uint256(1))
        );
        // Before any execution, delegationCap[key] is 0, so remainingNotional
        // returns 0 (cap not yet set). First execution initializes cap.
        assertEq(agent.remainingNotional(VENUE, DELEGATOR, d), 0);
        vm.prank(VENUE);
        assertTrue(agent.recordExecution(VENUE, DELEGATOR, d, 100, bytes32(uint256(1)), 0));
        assertEq(agent.remainingNotional(VENUE, DELEGATOR, d), 900);
    }

    // ---- Empty assetIds = all assets allowed (no restriction) ----

    function test_emptyAssetIds_allowed() public view {
        ITradeOnlyAgent.Delegation memory d = _mkEmptyDelegation();
        ITradeOnlyAgent.Signature memory sig = _sign(DELEGATOR_PK, DELEGATOR, d);
        assertTrue(agent.isValidDelegation(DELEGATOR, d, sig));
    }
}
