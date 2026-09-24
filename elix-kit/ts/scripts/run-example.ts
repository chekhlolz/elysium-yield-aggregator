/**
 * Example: deploy HelloElysium against a local Anvil instance.
 *
 * Requires:
 *   - Anvil running at 127.0.0.1:8545 with --chain-id 999
 *   - `forge build` already run in ../solidity (artifacts in
 *     ../solidity/out/)
 *   - A DEPLOYER_PK that has ETH (Anvil's default dev key works)
 *
 * Usage:
 *   npm run example
 */

import { ElysiumClient } from "../src/index";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
// Hardhat dev key #0 — NEVER use this for real funds.
const DEPLOYER_PK =
  process.env.DEPLOYER_PK ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const CHAIN_ID = Number(process.env.CHAIN_ID ?? "999");

async function main(): Promise<void> {
  const client = new ElysiumClient({
    rpcUrl: RPC_URL,
    deployerPk: DEPLOYER_PK,
    chainId: CHAIN_ID,
  });
  const addr = await client.getDeployerAddress();
  console.log(`deployer: ${addr}`);
  console.log(`rpc:      ${RPC_URL}`);
  console.log(`chainId:  ${CHAIN_ID}`);

  const { contract } = await client.deployHelloElysium(
    "Hello from Elysium",
    "../solidity/out/HelloElysium.sol/HelloElysium.json",
  );
  const hello = await contract.hello();
  console.log(`hello(): "${hello}"`);
  console.log(`address: ${await contract.getAddress()}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
