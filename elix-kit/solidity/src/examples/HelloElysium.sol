// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title HelloElysium
 * @notice Trivial greeting contract — smoke-tests the toolchain and the
 *         Foundry workflow. If you can deploy this and read `hello()`,
 *         you have RPC access to a working EVM.
 *
 * @dev This contract is deliberately boring: one mutable string, one
 *      setter, no permissions, no state machine. It exists to answer
 *      "is my deploy pipeline working?" in <5 minutes.
 */
contract HelloElysium {
    string public hello;

    event HelloSet(string newHello);

    constructor() {
        hello = "Hello from Elysium";
    }

    /**
     * @dev Set the greeting. Open by design — this is a teaching
     *      contract, not a production one. Real apps should add
     *      `Ownable` or a role-check.
     */
    function setHello(string calldata _hello) external {
        require(bytes(_hello).length > 0, "HelloElysium: empty");
        hello = _hello;
        emit HelloSet(_hello);
    }
}
