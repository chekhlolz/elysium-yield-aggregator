// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HelloElysium} from "../src/examples/HelloElysium.sol";

contract HelloElysiumTest is Test {
    HelloElysium hello;

    function setUp() public {
        hello = new HelloElysium();
    }

    function test_DefaultGreeting() public view {
        assertEq(hello.hello(), "Hello from Elysium");
    }

    function test_SetHelloUpdatesValue() public {
        vm.expectEmit(false, false, false, true);
        emit HelloElysium.HelloSet("Hi Elysium");
        hello.setHello("Hi Elysium");
        assertEq(hello.hello(), "Hi Elysium");
    }

    function test_SetHelloRejectsEmptyString() public {
        vm.expectRevert(bytes("HelloElysium: empty"));
        hello.setHello("");
    }

    function test_SetHelloIsOpen() public {
        // The contract is deliberately permissionless — anyone can
        // set the greeting. This is a teaching contract, not a
        // production one.
        vm.prank(address(0xdead));
        hello.setHello("Anonymous greeted");
        assertEq(hello.hello(), "Anonymous greeted");
    }
}
