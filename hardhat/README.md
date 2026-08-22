# Ritual Predict contracts

The Hardhat workspace contains the production prediction-market contract, canonical Ritual mocks, Solidity tests, and local/testnet scripts. The full Proof of Building notes are in [../README.md](../README.md) and [../docs/BUILD_LOG.md](../docs/BUILD_LOG.md).

## Layout

```text
contracts/
  RitualPredict.sol          market lifecycle + multi-oracle retry rotation
  RitualPredict.t.sol        12 Solidity tests
  ritual/RitualChain.sol     canonical Ritual addresses + interfaces
  mocks/RitualMocks.sol      local stand-ins for Scheduler/Wallet/TEE/HTTP/JQ
scripts/
  local-smoke.ts             external Hardhat-node fallback-rotation walkthrough
  block-time.ts              measure Ritual block time when testnet is available
  deploy.ts                  deploy + prepay execution fees
  fund.ts                    top up the prepaid execution balance
  status.ts                  print market state
  create-demo-market.ts      create a sample market on Ritual
  export-abi.ts              export ABI if a frontend is added later
```

The upstream scripts reference a `web/` directory, but this repository does not contain a frontend. `export-abi.ts` is therefore retained as a future integration helper, not claimed as a currently runnable frontend step.

## Offline commands

No `.env`, private key, Ritual RPC, or funded account is needed:

```bash
pnpm install --frozen-lockfile
pnpm exec hardhat build
pnpm exec tsc --noEmit
pnpm exec hardhat test solidity
```

Expected test result:

```text
12 passing
```

For the separate local-node verification:

```bash
# terminal 1
pnpm exec hardhat node

# terminal 2
pnpm exec hardhat run scripts/local-smoke.ts --network localhost
```

Expected final line:

```text
[local] PASS market #1: primary failed, fallback resolved YES at 4000
```

The unit suite uses `vm.etch` and the smoke script uses `hardhat_setCode` so the mock runtime code lives at the exact canonical Ritual addresses used by the production contract.

## Testnet commands

Only when Ritual testnet access is available:

```bash
cp .env.example .env
# set RITUAL_PRIVATE_KEY locally, never commit .env

pnpm exec hardhat run scripts/block-time.ts --network ritual
pnpm exec hardhat run scripts/deploy.ts --network ritual
PREDICT_ADDRESS=0x... pnpm exec hardhat run scripts/status.ts --network ritual
PREDICT_ADDRESS=0x... pnpm exec hardhat run scripts/fund.ts --network ritual
```
