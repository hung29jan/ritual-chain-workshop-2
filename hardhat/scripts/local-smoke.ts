import assert from "node:assert/strict";
import { network } from "hardhat";
import { parseEther } from "viem";

const ADDR = {
  scheduler: "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B",
  ritualWallet: "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948",
  teeRegistry: "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F",
  http: "0x0000000000000000000000000000000000000801",
  jq: "0x0000000000000000000000000000000000000803",
} as const;

async function rpc(method: string, params: unknown[] = []) {
  const response = await fetch("http://127.0.0.1:8545", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const payload = (await response.json()) as {
    result?: unknown;
    error?: { message?: string };
  };
  if (payload.error) throw new Error(`${method}: ${payload.error.message ?? "RPC error"}`);
  return payload.result;
}

const { viem } = await network.create({ network: "localhost", chainType: "l1" });
const publicClient = await viem.getPublicClient();
const [deployer, alice, bob] = await viem.getWalletClients();
if (!deployer || !alice || !bob) throw new Error("Local Hardhat node did not expose three unlocked accounts");

async function etch(contractName: "MockScheduler" | "MockRitualWallet" | "MockTEERegistry" | "MockHTTPPrecompile" | "MockJQPrecompile", target: `0x${string}`) {
  const implementation = await viem.deployContract(contractName);
  const bytecode = await publicClient.getCode({ address: implementation.address });
  if (!bytecode || bytecode === "0x") throw new Error(`No runtime code for ${contractName}`);
  await rpc("hardhat_setCode", [target, bytecode]);
}

console.log("[local] installing Ritual mocks at canonical addresses");
await etch("MockScheduler", ADDR.scheduler);
await etch("MockRitualWallet", ADDR.ritualWallet);
await etch("MockTEERegistry", ADDR.teeRegistry);
await etch("MockHTTPPrecompile", ADDR.http);
await etch("MockJQPrecompile", ADDR.jq);

const scheduler = await viem.getContractAt("MockScheduler", ADDR.scheduler);
const registry = await viem.getContractAt("MockTEERegistry", ADDR.teeRegistry);
const http = await viem.getContractAt("MockHTTPPrecompile", ADDR.http);
const jq = await viem.getContractAt("MockJQPrecompile", ADDR.jq);

await registry.write.configure([deployer.account.address, true]);
await http.write.configure([500, "0x646f776e", "", false]); // "down"
await jq.write.configure([4000n, false]);

const predict = await viem.deployContract("RitualPredict", [1000n]);
console.log(`[local] RitualPredict deployed at ${predict.address}`);

const primary = "https://primary.example/eth";
const fallback = "https://fallback.example/eth";
const params = {
  question: "Will ETH/USD be at least 4000?",
  oracleUrl: primary,
  jsonPath: ".price",
  target: 4000n,
  comparator: 1,
  bettingSeconds: 30n,
  resolveDelaySeconds: 15n,
} as const;

await predict.write.createMarketWithFallbacks([params, [fallback]]);
const marketId = await predict.read.marketCount();

await predict.write.bet([marketId, true], { account: alice.account, value: parseEther("1") });
await predict.write.bet([marketId, false], { account: bob.account, value: parseEther("1") });

let market = await predict.read.getMarket([marketId]);
const currentBlock = await publicClient.getBlockNumber();
if (market.resolveBlock > currentBlock) {
  const blocks = market.resolveBlock - currentBlock;
  await rpc("hardhat_mine", [`0x${blocks.toString(16)}`]);
}

console.log("[local] forcing primary oracle failure");
await scheduler.write.fire([predict.address, 0n, marketId]);
assert.equal(await http.read.lastUrl(), primary);
market = await predict.read.getMarket([marketId]);
assert.equal(market.attempts, 1);
assert.equal(market.state, 2); // Resolving

console.log("[local] making fallback oracle healthy for retry 2");
await http.write.configure([200, "0x7b227072696365223a343030307d", "", false]); // {"price":4000}
await scheduler.write.fire([predict.address, 1n, marketId]);

assert.equal(await http.read.lastUrl(), fallback);
market = await predict.read.getMarket([marketId]);
assert.equal(market.attempts, 2);
assert.equal(market.state, 3); // Resolved
assert.equal(market.outcome, 1); // YES
assert.equal(market.observedValue, 4000n);

console.log(`[local] PASS market #${marketId}: primary failed, fallback resolved YES at 4000`);
