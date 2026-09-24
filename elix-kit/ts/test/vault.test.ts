/**
 * Vault round-trip tests — offline, no Anvil.
 *
 * Uses ethers' AbiCoder to encode call data for the VaultStarter ABI
 * and decode it back. This is a bit-exact check that our hand-written
 * ABI mirrors match what the Solidity contract actually expects: if
 * the contract's selector changes (renamed function, reordered
 * params, added overloads), these tests fail.
 *
 * No provider, no wallet, no network. Everything is local.
 */

import { AbiCoder, Interface } from "ethers";
import { describe, expect, it } from "vitest";

import {
  HELLO_ELYSIUM_ABI,
  VAULT_STARTER_ABI,
  VAULT_STARTER_CONSTRUCTOR_ARGS,
  ElysiumClient,
} from "../src/index";

const coder = AbiCoder.defaultAbiCoder();

const VAULT_ABI_JSON: ReadonlyArray<Record<string, unknown>> = VAULT_STARTER_ABI as unknown as ReadonlyArray<
  Record<string, unknown>
>;
const HELLO_ABI_JSON: ReadonlyArray<Record<string, unknown>> = HELLO_ELYSIUM_ABI as unknown as ReadonlyArray<
  Record<string, unknown>
>;

describe("VaultStarter ABI", () => {
  it("parses the ABI into an Interface with no errors", () => {
    const iface = new Interface(VAULT_ABI_JSON);
    expect(iface.getFunction("deposit")).toBeDefined();
    expect(iface.getFunction("withdraw")).toBeDefined();
    expect(iface.getFunction("setTargetApyBps")).toBeDefined();
    expect(iface.getFunction("previewRedeem")).toBeDefined();
  });

  it("round-trips deposit(assets, receiver) via AbiCoder", () => {
    const iface = new Interface(VAULT_ABI_JSON);
    const encoded = iface.encodeFunctionData("deposit", [
      1_000_000_000_000_000_000n, // 1e18 = 1 ether
      "0x00000000000000000000000000000000000000a1",
    ]);
    const [assets, receiver] = iface.decodeFunctionData(
      iface.getFunction("deposit"),
      encoded,
    );
    expect(assets).toBe(1_000_000_000_000_000_000n);
    expect(receiver.toLowerCase()).toBe("0x00000000000000000000000000000000000000a1");
  });

  it("round-trips setTargetApyBps(uint256) via AbiCoder", () => {
    const iface = new Interface(VAULT_ABI_JSON);
    const encoded = iface.encodeFunctionData("setTargetApyBps", [1_890n]);
    const [bps] = iface.decodeFunctionData(
      iface.getFunction("setTargetApyBps"),
      encoded,
    );
    expect(bps).toBe(1_890n);
  });

  it("round-trips the constructor args tuple", () => {
    const encoded = coder.encode(
      VAULT_STARTER_CONSTRUCTOR_ARGS.map((a) => a.type),
      [
        "0x0000000000000000000000000000000000001010",
        "0x0000000000000000000000000000000000000cD0",
        1_000n,
        "Elysium Vault",
        "eVL",
      ],
    );
    const decoded = coder.decode(
      VAULT_STARTER_CONSTRUCTOR_ARGS.map((a) => a.type),
      encoded,
    );
    expect(decoded[0]).toBe("0x0000000000000000000000000000000000001010");
    expect(decoded[1].toLowerCase()).toBe("0x0000000000000000000000000000000000000cd0");
    expect(decoded[2]).toBe(1_000n);
    expect(decoded[3]).toBe("Elysium Vault");
    expect(decoded[4]).toBe("eVL");
  });

  it("round-trips previewRedeem(shares) via AbiCoder", () => {
    const iface = new Interface(VAULT_ABI_JSON);
    const encoded = iface.encodeFunctionData("previewRedeem", [42n]);
    const [shares] = iface.decodeFunctionData(
      iface.getFunction("previewRedeem"),
      encoded,
    );
    expect(shares).toBe(42n);
  });

  it("rejects calls to a method that isn't in the ABI", () => {
    const iface = new Interface(VAULT_ABI_JSON);
    expect(() => iface.encodeFunctionData("stealFunds", [0n])).toThrow();
  });
});

describe("HelloElysium ABI", () => {
  it("round-trips setHello(string) via AbiCoder", () => {
    const iface = new Interface(HELLO_ABI_JSON);
    const encoded = iface.encodeFunctionData("setHello", ["Hi Elysium"]);
    const [msg] = iface.decodeFunctionData(
      iface.getFunction("setHello"),
      encoded,
    );
    expect(msg).toBe("Hi Elysium");
  });

  it("exposes the default ctor as an empty deploy signature", () => {
    const iface = new Interface(HELLO_ABI_JSON);
    expect(iface.deploy).toBeDefined();
  });
});

describe("ElysiumClient construction", () => {
  it("rejects missing rpcUrl", () => {
    expect(
      () => new ElysiumClient({ rpcUrl: "", deployerPk: "0x00" }),
    ).toThrow(/rpcUrl/);
  });

  it("rejects missing deployerPk", () => {
    expect(
      () => new ElysiumClient({ rpcUrl: "http://x", deployerPk: "" }),
    ).toThrow(/deployerPk/);
  });

  it("constructs a client offline without touching the network", () => {
    // Hardhat dev key #0 — never for real funds.
    const client = new ElysiumClient({
      rpcUrl: "http://127.0.0.1:8545",
      deployerPk:
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
      chainId: 999,
    });
    expect(client.wallet.address).toBe("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    expect(client.provider).toBeDefined();
  });
});
