# Proof of Building log

This file records the failures that actually happened while turning the workshop starter into a reproducible offline build. It is intentionally not a polished success-only narrative.

## 1. Initial clone and dependency baseline could not run in the assistant shell

The first requested step was to clone the public fork before changing anything. The shell environment used for the work had outbound DNS/network access disabled.

Observed clone error:

```text
fatal: unable to access 'https://github.com/hung29jan/ritual-chain-workshop-2.git/':
Could not resolve host: github.com
```

`pnpm` was also not preinstalled, and Corepack could not download it:

```text
getaddrinfo EAI_AGAIN registry.npmjs.org
```

Because there was no local Hardhat/Foundry/solc toolchain either, no baseline build result was fabricated. The repository was audited through the authenticated GitHub API, then clean GitHub Actions runners were used for installation, compile, tests, and a local Hardhat node.

## 2. Starter source and README did not match

Before changes, `hardhat/README.md` claimed the repository included `RitualPredict.t.sol`, `mocks/RitualMocks.sol`, `RitualPredict.e2e.ts`, and 35 tests. The actual tree contained none of those files. It only contained the default `test/Counter.ts`, while there was no `Counter.sol` to deploy.

The main `RitualPredict.sol` also contained unfinished `// we'll fill this up` bodies in the core market creation, Scheduler callback, HTTP oracle path, executor selection, and scheduling functions.

The deployment scripts additionally referenced a `web/` directory that did not exist.

Fix: complete the production lifecycle, remove the stale Counter suite, create the missing canonical-address mocks and real prediction-market tests, and update documentation to describe the repository that actually exists.

## 3. Hardhat private-key configuration disagreed with `.env.example`

`.env.example` and the scripts used `RITUAL_PRIVATE_KEY`, but the latest upstream `hardhat.config.ts` had been changed to `DEPLOYER_PRIVATE_KEY` and no longer loaded `.env`.

Fix: restore best-effort `process.loadEnvFile()` and consistently use optional `RITUAL_PRIVATE_KEY`. Offline compile/tests do not require a key and `.env` remains ignored.

## 4. First clean CI compile failed on the JQ mock fallback

The first GitHub Actions verification run reached Solidity compilation and failed with:

```text
TypeError: Fallback function must be payable or non-payable, but is "view".
--> contracts/mocks/RitualMocks.sol
```

I had declared `MockJQPrecompile`'s fallback as `view` because the production contract reaches JQ through `STATICCALL`. Solidity does not allow that state-mutability modifier on a fallback.

Fix: make the fallback a normal nonpayable function and keep its body read-only. `STATICCALL` still enforces that no state writes can happen at runtime.

## 5. Second clean CI compile hit `Stack too deep`

After the fallback fix, compilation progressed into `RitualPredict._readOracle` and failed with:

```text
CompilerError: Stack too deep. Try compiling with `--via-ir`
...
contracts/RitualPredict.sol ... m.jsonPath
```

The HTTP precompile request has 13 ABI fields, and the same function also holds response-decoding and JQ parsing values. This exhausted the legacy compiler stack allocator.

Fix: keep the optimizer enabled and set `viaIR: true` in both Hardhat Solidity profiles. The next clean run compiled all four Solidity files successfully.

## 6. TypeScript scripts failed typecheck after Solidity compiled

The next clean run passed Solidity build but `pnpm exec tsc --noEmit` returned `TS5097` for existing scripts such as `block-time.ts`, `create-demo-market.ts`, and `deploy.ts`:

```text
An import path can only end with a '.ts' extension when
'allowImportingTsExtensions' is enabled.
```

The repo intentionally uses ESM imports like `./ritual.ts` but its `tsconfig.json` did not enable that form.

Fix: enable `allowImportingTsExtensions` and `noEmit` in `tsconfig.json`. The following clean run passed typecheck.

## 7. First real Solidity test run exposed an ABI-layout bug in the HTTP mock

Once build and typecheck were green, the test suite ran for the first time. Eight tests passed and four failed. The fallback-rotation assertions showed `lastUrl` as an empty string, and happy-path resolution stayed in `Resolving` instead of reaching `Resolved`.

Diagnosis: production encodes the Ritual HTTP request as 13 flat ABI arguments. The mock tried to decode those bytes as one `HTTPRequest` struct tuple. Those two ABI layouts are not equivalent for a dynamic tuple, so the mock fallback reverted before recording the URL. The contract correctly treated that revert as an oracle failure, which is why the retry-failure tests still passed and initially obscured the mock bug.

Fix: decode the exact 13-field flat wire layout in `MockHTTPPrecompile` and extract the sixth field, the URL. The next run passed all 12 Solidity tests.

## 8. Final verified local flow

The successful clean GitHub Actions run performed:

```text
pnpm install --frozen-lockfile
pnpm exec hardhat build
pnpm exec tsc --noEmit
pnpm exec hardhat test solidity
pnpm exec hardhat node
pnpm exec hardhat run scripts/local-smoke.ts --network localhost
```

Solidity result:

```text
12 passing
```

Local-node scenario result:

```text
[local] installing Ritual mocks at canonical addresses
[local] RitualPredict deployed at 0x2279b7a0a67db372996a5fab50d91eaa73d2ebe6
[local] forcing primary oracle failure
[local] making fallback oracle healthy for retry 2
[local] PASS market #1: primary failed, fallback resolved YES at 4000
```

The local node contains no Ritual state by default. `local-smoke.ts` deploys the mock implementations and uses `hardhat_setCode` to place their runtime bytecode at the canonical Scheduler, RitualWallet, TEE registry, HTTP, and JQ addresses before deploying `RitualPredict`.

## Security hygiene

- No `.env` file is committed.
- No private key, seed phrase, API key, or funded account credential is required by the offline workflow.
- `.env.example` contains only placeholders.
- The repository remains a public GitHub fork with upstream lineage intact.
