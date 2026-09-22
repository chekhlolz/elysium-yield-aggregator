// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IERC20Minimal + SafeERC20
 * @notice Minimal ERC-20 surface and a raw-call wrapper that tolerates
 *         non-standard tokens (no bool return, empty return data, etc.).
 *         Kept as a single file so each leg has one import to add.
 *
 * @dev Mirrors the pattern used by YieldAggregator.sol; that contract
 *      keeps its own local copies for self-containment, but every leg
 *      in `src/legs/` imports from this file.
 */
interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20Minimal tok, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(
            abi.encodeCall(IERC20Minimal.transfer, (to, v))
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 transfer failed");
    }

    function safeTransferFrom(IERC20Minimal tok, address from, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(
            abi.encodeCall(IERC20Minimal.transferFrom, (from, to, v))
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 transferFrom failed");
    }

    function safeApprove(IERC20Minimal tok, address to, uint256 v) internal {
        (bool ok, bytes memory data) = address(tok).call(
            abi.encodeCall(IERC20Minimal.approve, (to, v))
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "erc20 approve failed");
    }
}
