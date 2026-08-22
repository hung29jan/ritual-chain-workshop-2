# Ritual Predict

A self-resolving binary prediction market built for Ritual Chain and extended for the Bootcamp 2 Proof of Building.

Users stake the native asset on YES or NO. Resolution is booked with Ritual Scheduler when the market is created. At the scheduled block the contract selects a TEE HTTP executor, reads an oracle through the HTTP precompile at `0x0801`, extracts a `uint256` through the synchronous JQ precompile at `0x0803`, compares it with the immutable target, and settles the market. Winners pull their proportional share of the pool.

## What I added

The main extension in this fork is **multi-oracle retry rotation**.

`createMarketWithFallbacks()` accepts the primary oracle plus up to two immutable fallback endpoints. Because the Scheduler books three attempts, resolution can use a different endpoint on each retry:

```text
attempt 1 -> primary oracle
attempt 2 -> fallback oracle 1
attempt 3 -> fallback oracle 2
```

With only one fallback, attempt 3 cycles back to the primary. Existing callers can still use `createMarket()` with one oracle. Duplicate, empty, or excessive fallback URLs are rejected at market creation.

This is intentionally tied to Ritual's execution model. Each Scheduler retry is a separate transaction, so rotating an endpoint does not violate the rule that a transaction may contain only one short-running async precompile call. The HTTP response can still be passed to the synchronous JQ precompile in the same scheduled transaction.

I also completed the unfinished market lifecycle in the starter repo, added canonical-address Ritual mocks, removed the stale Counter test, fixed the Hardhat/TypeScript configuration, and added a clean offline verification workflow.

## Why these design choices

**Block-number deadlines instead of timestamps.** Ritual Scheduler fires at a block number, so the betting close and resolution trigger use the same clock domain. This also avoids accidentally treating Ritual's millisecond timestamps as normal EVM seconds.

**Oracle failure is not a NO result.** A failed HTTP call, non-200 response, malformed async envelope, missing executor, or invalid JQ output is an infrastructure failure. It consumes a retry and eventually makes the market `Invalid`, allowing refunds, rather than changing the economic outcome to NO.

**Fallback endpoints are immutable.** A creator cannot change the data source after users have placed bets. The primary rule and fallback list are fixed when the market is created and emitted as events.

**Pull-based payouts.** `claimWinnings()` calculates one user's pari-mutuel share in O(1) time. The contract never loops over all bettors, and settlement state is written before sending value to protect the claim path from re-entrancy.

**Canonical-address mocks.** Local EVMs do not contain Ritual's Scheduler, RitualWallet, TEE registry, HTTP precompile, or JQ precompile. Tests copy mock runtime bytecode to the real Ritual addresses so the production contract is exercised without replacing those addresses with test-only constructor parameters.

## Important addresses used by the contract

| Component | Address |
| --- | --- |
| Scheduler | `0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B` |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| TEE Service Registry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| HTTP precompile | `0x0000000000000000000000000000000000000801` |
| JQ precompile | `0x0000000000000000000000000000000000000803` |

## Offline verification

The Ritual testnet is not required for the Proof of Building path.

Requirements:

- Node.js 22
- pnpm 10

From a clean clone:

```bash
cd hardhat
pnpm install --frozen-lockfile
pnpm exec hardhat build
pnpm exec tsc --noEmit
pnpm exec hardhat test solidity
```

The Solidity suite installs mock code at the canonical Ritual addresses with `vm.etch` and currently covers 12 market, failure-path, payout, authorization, and fallback-rotation cases.

To reproduce the separate-process local-node flow, open two terminals.

Terminal 1:

```bash
cd hardhat
pnpm exec hardhat node
```

Terminal 2:

```bash
cd hardhat
pnpm exec hardhat run scripts/local-smoke.ts --network localhost
```

The smoke script deploys mock implementations, injects their runtime bytecode into the canonical Ritual addresses with `hardhat_setCode`, creates a market with a fallback, intentionally makes the primary oracle fail, then makes retry 2 succeed through the fallback. Expected final line:

```text
[local] PASS market #1: primary failed, fallback resolved YES at 4000
```

GitHub Actions runs the same clean sequence in `.github/workflows/offline-verify.yml`.

## Testnet configuration

`.env` is ignored and must never be committed. Copy `.env.example` only when testnet access is available:

```bash
cd hardhat
cp .env.example .env
```

The expected key name is `RITUAL_PRIVATE_KEY`. No key is required for compile, unit tests, or the local-node smoke flow.

## Repository layout

```text
hardhat/
  contracts/
    RitualPredict.sol
    RitualPredict.t.sol
    ritual/RitualChain.sol
    mocks/RitualMocks.sol
  scripts/
    local-smoke.ts
    block-time.ts
    deploy.ts
    fund.ts
    status.ts
    create-demo-market.ts
    export-abi.ts
  hardhat.config.ts
  tsconfig.json
.github/workflows/offline-verify.yml
docs/BUILD_LOG.md
```

The original repository contains scripts that refer to a `web/` frontend, but no `web/` directory exists in the source tree. This fork focuses on the smart-contract, testing, local-node, and contract-extension rubric items instead of pretending that missing frontend is present.

## Build notes

Real errors encountered while making the fork reproducible, including the initial environment failure, Solidity fallback restriction, `Stack too deep`, TypeScript extension imports, and the HTTP mock ABI mismatch, are recorded in [`docs/BUILD_LOG.md`](docs/BUILD_LOG.md).

## References

- Ritual Chain docs: <https://docs.ritualfoundation.org>
- Ritual dApp skills: <https://github.com/ritual-foundation/ritual-dapp-skills>
- Upstream workshop: <https://github.com/cozfuttu/ritual-chain-workshop-2>
