// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {HyperCoreSnapshotMock} from "../src/HyperCoreSnapshotMock.sol";
import {Fixture} from "./fixtures/HYPE.ts.sol";

contract FixtureSmokeTest is Test {
    function test_FixtureLoads() public {
        HyperCoreSnapshotMock snap = new HyperCoreSnapshotMock(
            Fixture.candles(), Fixture.funding(), Fixture.market()
        );
        assertEq(snap.candleCount(), 2, "2 candles");
        assertEq(snap.fundingCount(), 2, "2 funding ticks");
        assertEq(snap.marketCount(), 1, "1 market data");
    }
}
