// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./ITradeOnlyAgent.sol";

/**
 * @title IElysiumCoreWriter
 * @notice Stub interface for the ElysiumCoreWriter predeploy that
 *         ships ~4 weeks post-mainnet (see docs/AGGREGATOR_SPEC.md §2).
 *         Legs route every perp operation through this writer; no leg
 *         talks to HyperCore state directly.
 *
 * @dev The real ElysiumCoreWriter is a predeploy. This stub only
 *      exposes the intent-level API the legs need today — the real
 *      contract will add order book, liquidation, and margin
 *      primitives in the months that follow mainnet.
 *
 *      Execution is delegation-gated: every intent carries a signed
 *      ITradeOnlyAgent.Delegation + Signature that the writer (or its
 *      venue-side hook) verifies before accepting the order.
 */
interface IElysiumCoreWriter {
    /// Perp order side.
    enum Side { Long, Short }

    /** Open a perp position under a signed delegation. */
    function openPosition(
        uint256 assetId,
        Side side,
        uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external;

    /** Close a perp position under a signed delegation. */
    function closePosition(
        uint256 assetId,
        Side side,
        uint256 notional,
        address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external;
}
