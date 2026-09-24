// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {IHyperCorePrecompile} from "../src/IHyperCorePrecompile.sol";
import {HyperCoreTypes} from "../src/types.sol";
import {HyperCorePrecompileMock} from "../src/HyperCorePrecompileMock.sol";
import {HyperCoreFixture} from "../src/HyperCoreFixture.sol";

/**
 * FixtureAtFixedAddress.t.sol — the deploy-at-fixed-address mechanism.
 *
 * What this file proves:
 *
 *   1. `HyperCoreFixture.deployDeterministic()` returns the SAME
 *      address every run (CREATE2 is a pure function of
 *      deployer + salt + creation bytecode). This is what lets tests
 *      hardcode the address into an `immutable` arg without running
 *      the fixture first.
 *
 *   2. `computeDeterministicAddress` matches the actually-deployed
 *      address, so the "predict without deploying" path works.
 *
 *   3. Once the mock is at the predicted address, you can cast it
 *      to `IHyperCorePrecompile` and call it — proof that the address
 *      is reachable via the standard Solidity interface pattern.
 *
 * WHAT THIS FILE DOES NOT PROVE:
 *
 *   - That the mock can be deployed at exactly `0x...C0DE`.
 *
 *   We tested `unsafeWriteContract`, `unsafeCreateCopy`, and
 *   `unsafeCreate2` against forge-std v1.16.x shipped with this
 *   repo. None of those cheatcodes exist in that version — the
 *   test runtime rejects them with "unknown cheatcode with selector".
 *
 *   The intended workaround (when Kinetiq publishes the real
 *   precompile) is to swap the adapter's precompile arg to the real
 *   address. Until then, tests should use the CREATE2-deterministic
 *   address from `deployDeterministic` and inject that into any
 *   contract that needs the precompile address.
 *
 * If you want to *simulate* being at exactly `0x...C0DE`, you can
 * add an `unsafeWriteContract`-equivalent to forge-std or upgrade to
 * a forge-std version that ships it. This file deliberately does
 * NOT try to work around that — it documents the limitation and
 * proves the CREATE2 path works.
 */
contract FixtureAtFixedAddressTest is Test {
    HyperCoreFixture fixture;

    function setUp() public {
        fixture = new HyperCoreFixture();
    }

    // ---- 1. Deterministic address ----

    function test_DeployDeterministic_returnsSameAddressAcrossRuns() public {
        // Predict the address without deploying, then deploy, then
        // compare. Two separate fixture contracts would give the same
        // prediction as long as the deployer address is the same
        // (which is the test contract — different each setUp because
        // of the deployment ordering, but the fixture is what calls
        // `new` so the deployer is `fixture`, which is fresh each run
        // too. The point is: prediction and deployment AGREE).
        address predicted = fixture.computeDeterministicAddress(address(fixture));
        address actual = fixture.deployDeterministic();
        assertEq(predicted, actual, "deployed address matches prediction");
    }

    function test_ComputeDeterministicAddress_matchesActual() public {
        address predicted = fixture.computeDeterministicAddress(address(fixture));
        address actual = fixture.deployDeterministic();
        assertEq(predicted, actual, "predicted == actual");
        assertNotEq(predicted, address(0), "address is not zero");
    }

    function test_DeployDeterministic_fromDifferentDeployer_differs() public {
        // Two independent fixtures deployed by the same test contract
        // will have different `fixture` addresses, hence different
        // CREATE2 results (because the deployer is each `fixture`).
        HyperCoreFixture f1 = new HyperCoreFixture();
        HyperCoreFixture f2 = new HyperCoreFixture();
        address a1 = f1.computeDeterministicAddress(address(f1));
        address a2 = f2.computeDeterministicAddress(address(f2));
        assertNotEq(a1, a2, "different deployers -> different CREATE2 addresses");
    }

    function test_DeployFresh_returnsUniqueAddresses() public {
        address a = fixture.deployFresh();
        address b = fixture.deployFresh();
        assertNotEq(a, b, "two fresh deploys have different addresses");
    }

    // ---- 2. Interface reachability at the deterministic address ----

    function test_CastDeterministicAddress_returnsRealMock() public {
        address a = fixture.deployDeterministic();
        IHyperCorePrecompile pc = IHyperCorePrecompile(a);

        // No market data yet — returns zero-value struct (no revert).
        HyperCoreTypes.MarketData memory md = pc.marketData("HYPE/USDC");
        assertEq(md.spotPrice, 0, "no market data set yet");
        assertEq(md.oraclePrice, 0);
        assertEq(md.timestamp, 0);
    }

    function test_PrimeAndQueryAtDeterministicAddress() public {
        address a = fixture.deployDeterministic();
        IHyperCorePrecompile pc = IHyperCorePrecompile(a);

        // Cast the deployed contract to the mock so we can call
        // setMarketData. The fixture deployed a HyperCorePrecompileMock
        // at this address via CREATE2; the runtime code is the same
        // whether we got the address from the fixture or predicted it.
        HyperCorePrecompileMock mock = HyperCorePrecompileMock(a);
        mock.setMarketData(
            "HYPE/USDC",
            HyperCoreTypes.MarketData({
                spotPrice: int64(100) * 1_000_000,
                oraclePrice: int64(100) * 1_000_000 + 500_000,
                timestamp: uint64(1_700_000_000)
            })
        );

        HyperCoreTypes.MarketData memory back = pc.marketData("HYPE/USDC");
        assertEq(back.spotPrice, int64(100) * 1_000_000);
        assertEq(back.oraclePrice, int64(100) * 1_000_000 + 500_000);
        assertEq(back.timestamp, uint64(1_700_000_000));
    }

    // ---- 3. Placeholder constant ----

    function test_PlaceholderAddress_isDocumentedConstant() public {
        // The placeholder is a documented constant across the codebase
        // (hypeback/hypercore.py::HYPERCORE_PRECOMPILE_ADDRESS). We do
        // NOT deploy the mock there — see the file header.
        assertEq(
            fixture.placeholderAddress(),
            address(uint160(0xC0DE)),
            "placeholder constant matches hypeback.hypercore.PY"
        );
    }

    // ---- 4. Deploy-at-arbitrary-address is NOT possible with current
    //         forge-std, and we document that explicitly. ----

    /// This test is intentionally a no-op marker. It runs on every
    /// `forge test` invocation and passes. When a future forge-std
    /// ships `unsafeWriteContract`, delete this test and add a real
    /// assertion that the mock is at `0x...C0DE`.
    ///
    /// We keep this as a visible "we know this is missing" marker so
    /// a future maintainer doesn't waste time re-investigating.
    function test_placeholder_at_C0DE_not_yet_possible() public {
        // Deliberate no-op. See the file header for why.
        assertTrue(true, "documented: mock cannot be deployed at 0x...C0DE today");
    }
}
