// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IHyperCorePrecompile} from "./IHyperCorePrecompile.sol";
import {HyperCorePrecompileMock} from "./HyperCorePrecompileMock.sol";
import {HyperCoreSnapshotMock, SnapshotInput} from "./HyperCoreSnapshotMock.sol";

/**
 * @title HyperCoreFixture
 * @notice Test helper that deploys a `HyperCorePrecompileMock` (or a
 *         snapshot mock) and hands back its address for injection.
 *
 * The placeholder address used across the hypeback codebase is
 * `0x000000000000000000000000000000000000C0DE` — see
 * `hypeback/hypercore.py::HYPERCORE_PRECOMPILE_ADDRESS`. On Elysium
 * mainnet Kinetiq will publish the real predeploy at that address.
 *
 * We cannot write raw bytecode to an arbitrary address in a local
 * test: forge-std v1.16.x does not ship `unsafeWriteContract` or
 * `unsafeCreateCopy`, so there is no clean way to land a mock at
 * exactly `0x...C0DE`. This fixture solves the problem with CREATE2
 * — the returned address is deterministic across runs, so tests can
 * inject it into contracts with `immutable` addresses.
 *
 * Trade-off notes:
 *   - `deployDeterministic()` returns a CREATE2-derived address that
 *     is NOT `0x...C0DE`. If your test needs to call
 *     `IHyperCorePrecompile(0x...C0DE).marketData(...)`, the mock
 *     will not be reachable at that address. Use `deployDeterministic`
 *     + `MarketDataFeedAdapter` to bridge.
 *   - When Kinetiq publishes the real precompile spec, replace the
 *     adapter's precompile argument with the real address and drop
 *     the mock entirely — no other test code should need to change.
 *
 * Contract, not library — so you can `new HyperCoreFixture()` in a
 * test setUp() and call its external functions.
 */
contract HyperCoreFixture {
    // Mirror of hypeback/hypercore.py::HYPERCORE_PRECOMPILE_ADDRESS.
    // Kept here so tests can assert against the intended target even
    // when the mock is deployed at a different CREATE2 address.
    address public constant PLACEHOLDER_ADDRESS =
        address(uint160(0xC0DE));

    // Salt used by `deployDeterministic`. Bump the version string
    // whenever the mock's creation bytecode changes so old tests
    // don't silently pick up a stale artifact.
    bytes32 public constant DEPLOY_SALT =
        bytes32(keccak256("hypercore-dev-harness/v1"));

    event MockDeployed(address indexed precompile, bool deterministic);
    event SnapshotDeployed(address indexed precompile);

    /**
     * Deploy a fresh HyperCorePrecompileMock. Returns a unique address
     * on every call — safe for isolated unit tests.
     */
    function deployFresh() external returns (address precompile) {
        IHyperCorePrecompile pc = new HyperCorePrecompileMock();
        precompile = address(pc);
        emit MockDeployed(precompile, false);
    }

    /**
     * Deploy the mock via CREATE2 with a fixed salt. Returns the same
     * address every run, so tests can hardcode it (e.g. to inject
     * into a contract's immutable constructor arg).
     *
     * The returned address is deterministic given (msg.sender, salt,
     * bytecode). If you call this from multiple test contracts, the
     * address will differ between them because msg.sender differs.
     *
     * Returns: the address of the deployed mock.
     */
    function deployDeterministic() external returns (address precompile) {
        bytes32 salt = DEPLOY_SALT;
        precompile = address(new HyperCorePrecompileMock{salt: salt}());
        emit MockDeployed(precompile, true);
    }

    /**
     * Compute the address that `deployDeterministic` will return when
     * called from `from` (i.e. this contract) with the given bytecode.
     *
     * Useful for tests that need to predict the address without
     * actually deploying — e.g. setting it on a sibling contract
     * before the mock is deployed.
     */
    function computeDeterministicAddress(address from)
        external pure returns (address)
    {
        bytes memory code = type(HyperCorePrecompileMock).creationCode;
        bytes32 salt = DEPLOY_SALT;
        bytes32 codeHash = keccak256(code);
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), from, salt, codeHash)
        );
        return address(uint160(uint256(h)));
    }

    /**
     * Deploy a snapshot-based mock. Returns the address.
     */
    function deploySnapshot(
        SnapshotInput.CandleEntry[] memory candles,
        SnapshotInput.FundingEntry[] memory funding,
        SnapshotInput.MarketEntry[] memory market
    ) external returns (address precompile) {
        HyperCoreSnapshotMock snap = new HyperCoreSnapshotMock(
            candles, funding, market
        );
        precompile = address(snap);
        emit SnapshotDeployed(precompile);
    }

    /**
     * Return the placeholder address constant — for tests that just
     * want to assert against the intended target without deploying.
     */
    function placeholderAddress() external view returns (address) {
        return PLACEHOLDER_ADDRESS;
    }
}
