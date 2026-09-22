"""A mock Ethereum JSON-RPC provider for testing deploy.py without a live node.

Implements every method the deploy harness touches:
    eth_chainId
    eth_getTransactionCount
    eth_getGasPrice
    eth_maxPriorityFeePerGas
    eth_estimateGas
    eth_sendRawTransaction
    eth_getTransactionReceipt
    eth_getCode
    eth_blockNumber
    eth_getBlockByNumber

Every call is recorded on ``.calls`` (as ``(method, params)`` tuples) so
tests can assert against the exact RPC traffic. Contract addresses are
handed out on each ``eth_sendRawTransaction`` in sequence, so three
consecutive deployments yield three distinct, valid 20-byte checksummed
addresses.

No sockets are opened: this provider never reaches for the network.
"""

from __future__ import annotations

from typing import Any, Optional

from eth_utils import to_checksum_address
from web3.providers.rpc import HTTPProvider


def _ok(value: Any) -> dict:
    """Wrap a value in a JSON-RPC 2.0 success envelope."""
    return {"jsonrpc": "2.0", "id": 1, "result": value}


def _contract_address(seed: int) -> str:
    """Seed an integer into a valid 20-byte checksummed address."""
    # Pad to 40 hex chars so the address is unambiguously 20 bytes.
    return to_checksum_address(f"0x{seed:040x}")


class MockProvider(HTTPProvider):
    """A canned JSON-RPC provider that never touches the network."""

    # Defaults — override per-instance via __init__ if needed.
    DEFAULT_CHAIN_ID = 99801
    DEFAULT_GAS_PRICE = 20 * 10**9          # 20 gwei
    DEFAULT_MAX_PRIORITY_FEE = 1 * 10**9    # 1 gwei
    DEFAULT_ESTIMATE_GAS = 1_000_000
    DEFAULT_NONCE = 0
    DEFAULT_BLOCK_NUMBER = 1

    def __init__(
        self,
        chain_id: Optional[int] = None,
        gas_price: Optional[int] = None,
        max_priority_fee: Optional[int] = None,
        estimate_gas: Optional[int] = None,
        nonce: Optional[int] = None,
    ):
        super().__init__()  # sets up _batching_context and friends
        self.calls: list[tuple[str, list]] = []
        self._chain_id = chain_id if chain_id is not None else self.DEFAULT_CHAIN_ID
        self._gas_price = gas_price if gas_price is not None else self.DEFAULT_GAS_PRICE
        self._max_priority_fee = (
            max_priority_fee
            if max_priority_fee is not None
            else self.DEFAULT_MAX_PRIORITY_FEE
        )
        self._estimate_gas = (
            estimate_gas if estimate_gas is not None else self.DEFAULT_ESTIMATE_GAS
        )
        self._nonce = nonce if nonce is not None else self.DEFAULT_NONCE
        self._tx_counter = 0
        # tx_hash -> receipt dict, populated as transactions are "sent".
        self._receipts: dict[str, dict] = {}

    # ---- Public helpers for test assertions -----------------------------

    def calls_for(self, method: str) -> list[list]:
        """Return the params list for every call to ``method``."""
        return [params for m, params in self.calls if m == method]

    @property
    def tx_hashes(self) -> list[str]:
        return list(self._receipts.keys())

    # ---- JSON-RPC dispatch ---------------------------------------------

    def make_request(self, method: str, params: list) -> dict:
        self.calls.append((method, params))

        if method == "eth_chainId":
            return _ok(hex(self._chain_id))
        if method == "eth_getTransactionCount":
            return _ok(hex(self._nonce))
        if method == "eth_getGasPrice":
            return _ok(hex(self._gas_price))
        if method == "eth_maxPriorityFeePerGas":
            return _ok(hex(self._max_priority_fee))
        if method == "eth_estimateGas":
            return _ok(hex(self._estimate_gas))
        if method == "eth_sendRawTransaction":
            self._tx_counter += 1
            tx_hash = "0x" + f"{self._tx_counter:064x}"
            self._receipts[tx_hash] = self._build_receipt(tx_hash)
            return _ok(tx_hash)
        if method == "eth_getTransactionReceipt":
            tx_hash = params[0] if params else "0x" + "00" * 32
            # Always return a receipt (never None) so web3's
            # wait_for_transaction_receipt returns immediately.
            receipt = self._receipts.get(tx_hash) or self._build_receipt(tx_hash)
            return _ok(receipt)
        if method == "eth_getCode":
            return _ok("0x")
        if method == "eth_blockNumber":
            return _ok(hex(self.DEFAULT_BLOCK_NUMBER))
        if method == "eth_getBlockByNumber":
            return _ok(
                {
                    "number": hex(self.DEFAULT_BLOCK_NUMBER),
                    "hash": "0x" + "aa" * 32,
                    "parentHash": "0x" + "bb" * 32,
                    "nonce": "0x0000000000000000",
                    "sha3Uncles": "0x" + "00" * 32,
                    "logsBloom": "0x" + "00" * 256,
                    "transactions": [],
                    "size": "0x0",
                    "difficulty": "0x0",
                    "totalDifficulty": "0x0",
                    "extraData": "0x",
                    "gasLimit": hex(30_000_000),
                    "gasUsed": "0x0",
                    "minersFee": "0x0",
                    "miner": "0x" + "00" * 20,
                    "timestamp": "0x0",
                    "transactionsRoot": "0x" + "00" * 32,
                    "stateRoot": "0x" + "00" * 32,
                    "receiptsRoot": "0x" + "00" * 32,
                    "uncles": [],
                }
            )
        raise NotImplementedError(f"MockProvider: unhandled method {method!r}")

    # ---- Internals -----------------------------------------------------

    def _build_receipt(self, tx_hash: str) -> dict:
        """Build a successful contract-creation receipt for ``tx_hash``."""
        addr = _contract_address(self._tx_counter + 0x1000)
        return {
            "transactionHash": tx_hash,
            "transactionIndex": "0x0",
            "blockHash": "0x" + "22" * 32,
            "blockNumber": hex(self.DEFAULT_BLOCK_NUMBER),
            "from": "0x" + "ab" * 20,
            "to": None,  # contract creation
            "gas": hex(self._estimate_gas),
            "gasUsed": hex(self._estimate_gas // 2),
            "cumulativeGasUsed": hex(self._estimate_gas // 2),
            "effectiveGasPrice": hex(self._max_priority_fee),
            "status": "0x1",
            "contractAddress": addr,
            "logs": [],
            "logsBloom": "0x" + "00" * 256,
            "type": "0x2",
            "input": "0x",
            "value": "0x0",
        }
