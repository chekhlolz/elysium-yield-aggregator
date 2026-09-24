/**
 * ElysiumClient — a small helper that deploys the two contracts in
 * `../solidity/src/examples/` against an EVM-compatible RPC.
 *
 * Deliberately minimal:
 *   - No chain-specific code. Elysium's chainId is a placeholder
 *     (`999` for local Anvil) until Kinetiq publishes the value.
 *   - No retry / nonce management. If a deploy fails, retry manually.
 *   - No event subscription, no read helpers. That is what ethers'
 *     `Contract` class is for; this helper just wires up the ABI and
 *     returns an ethers `Contract` handle.
 *
 * Deployable bytecode is loaded lazily from `../solidity/out/` when
 * available. If you have not run `forge build` yet, the deploy helpers
 * throw a clear error pointing you at the build step.
 */

import {
  ContractFactory,
  JsonRpcProvider,
  type Contract,
  type ContractInterface,
  Wallet,
} from "ethers";
import { existsSync, readFileSync } from "node:fs";

import {
  HELLO_ELYSIUM_ABI,
  VAULT_STARTER_ABI,
  VAULT_STARTER_CONSTRUCTOR_ARGS,
  type DeployResult,
  type ElysiumClientOptions,
} from "./types";

function readArtifactBytecode(artifactPath: string): string {
  if (!existsSync(artifactPath)) {
    throw new Error(
      `artifact not found: ${artifactPath}. Run \`forge build --root solidity\` first.`,
    );
  }
  const raw = readFileSync(artifactPath, "utf-8");
  const parsed: unknown = JSON.parse(raw);
  if (typeof parsed !== "object" || parsed === null) {
    throw new Error(`artifact is not a JSON object: ${artifactPath}`);
  }
  const bytecode = (parsed as { bytecode?: unknown }).bytecode;
  if (typeof bytecode !== "string") {
    throw new Error(`artifact missing \`bytecode\` field: ${artifactPath}`);
  }
  return bytecode;
}

function deployViaFactory(
  factory: ContractFactory,
  args: unknown[],
): Promise<Contract> {
  return factory.deploy(...args) as Promise<Contract>;
}

export class ElysiumClient {
  readonly provider: JsonRpcProvider;
  readonly wallet: Wallet;

  constructor(opts: ElysiumClientOptions) {
    if (!opts.rpcUrl) throw new Error("ElysiumClient: rpcUrl is required");
    if (!opts.deployerPk) throw new Error("ElysiumClient: deployerPk is required");
    this.provider = new JsonRpcProvider(opts.rpcUrl, opts.chainId);
    this.wallet = new Wallet(opts.deployerPk, this.provider);
  }

  async getDeployerAddress(): Promise<string> {
    return this.wallet.address;
  }

  /**
   * Deploy a `HelloElysium` contract. Returns the deployed contract
   * handle plus the transaction receipt summary.
   *
   * `greeting` is ignored by the constructor (HelloElysium uses the
   * default ctor); it is accepted so callers can set the initial
   * greeting via a follow-up `setHello` in a single deploy flow.
   */
  async deployHelloElysium(
    greeting: string,
    artifactRoot: string = "solidity/out/HelloElysium.sol/HelloElysium.json",
  ): Promise<{ contract: Contract; result: DeployResult }> {
    const bytecode = readArtifactBytecode(artifactRoot);
    const iface: ContractInterface = HELLO_ELYSIUM_ABI;
    const factory = new ContractFactory(bytecode, iface, this.wallet);
    const contract = await deployViaFactory(factory, []);
    await contract.waitForDeployment();
    if (greeting && greeting !== "Hello from Elysium") {
      await (await contract.setHello(greeting)).wait();
    }
    return {
      contract,
      result: {
        address: await contract.getAddress(),
        tx: { hash: contract.deployTransaction.hash, blockNumber: undefined },
      },
    };
  }

  /**
   * Deploy a `VaultStarter` with the given target APY (bps).
   *
   * @param targetApyBps  0..10_000 (0..100%). Capped in the constructor.
   * @param hypeAddress   The ERC-20 address for the vault's underlying.
   *                      On Elysium, this is HYPE. In tests, use a mock.
   */
  async deployVaultStarter(
    targetApyBps: bigint,
    hypeAddress: string,
    artifactRoot: string = "solidity/out/VaultStarter.sol/VaultStarter.json",
    opts: { name?: string; symbol?: string } = {},
  ): Promise<{ contract: Contract; result: DeployResult }> {
    if (targetApyBps < 0n || targetApyBps > 10_000n) {
      throw new Error("deployVaultStarter: targetApyBps must be in [0, 10000]");
    }
    const bytecode = readArtifactBytecode(artifactRoot);
    const iface: ContractInterface = VAULT_STARTER_ABI;
    const factory = new ContractFactory(bytecode, iface, this.wallet);
    const name = opts.name ?? "Elysium Vault";
    const symbol = opts.symbol ?? "eVL";
    // Static assertion: these arg types must match the contract's ctor
    // signature. TS will not flag drift because both sides are
    // strings; keep VAULT_STARTER_CONSTRUCTOR_ARGS in sync by hand.
    const constructorTypes: readonly string[] = VAULT_STARTER_CONSTRUCTOR_ARGS.map(
      (a) => a.type,
    );
    const expectedOrder = ["address", "address", "uint256", "string", "string"];
    if (constructorTypes.join(",") !== expectedOrder.join(",")) {
      throw new Error(
        `deployVaultStarter: ctor arg types drifted; got [${constructorTypes.join(
          ",",
        )}], expected [${expectedOrder.join(",")}]. Update types.ts.`,
      );
    }
    const args: unknown[] = [
      hypeAddress,
      await this.getDeployerAddress(),
      targetApyBps,
      name,
      symbol,
    ];
    const contract = await deployViaFactory(factory, args);
    await contract.waitForDeployment();
    return {
      contract,
      result: {
        address: await contract.getAddress(),
        tx: { hash: contract.deployTransaction.hash, blockNumber: undefined },
      },
    };
  }
}

export { HELLO_ELYSIUM_ABI, VAULT_STARTER_ABI };
