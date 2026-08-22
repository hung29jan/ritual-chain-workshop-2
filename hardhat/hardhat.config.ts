import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { defineConfig } from "hardhat/config";

// Node 20+ can load .env without adding dotenv. Missing .env is expected in CI/local tests.
try {
  process.loadEnvFile();
} catch {
  // no local .env file
}

const soliditySettings = {
  optimizer: {
    enabled: true,
    runs: 200,
  },
  // Ritual's HTTP request ABI has 13 fields. The full resolution path also keeps
  // response-decoding and JQ values live, which can exceed the legacy stack allocator.
  // IR compilation is the compiler-recommended fix and keeps the code readable.
  viaIR: true,
} as const;

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: soliditySettings,
      },
      production: {
        version: "0.8.28",
        settings: soliditySettings,
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    localhost: {
      type: "http",
      chainType: "l1",
      url: "http://127.0.0.1:8545",
    },
    ritual: {
      type: "http",
      chainType: "l1",
      chainId: 1979,
      url: process.env.RITUAL_RPC_URL ?? "https://rpc.ritualfoundation.org",
      accounts: process.env.RITUAL_PRIVATE_KEY ? [process.env.RITUAL_PRIVATE_KEY] : [],
    },
  },
});
