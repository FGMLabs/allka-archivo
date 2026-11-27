import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

// The compiler version, the EVM target and the optimizer settings are pinned on
// purpose: the bytecode that is tested must be the bytecode that is deployed.
// Changing any of them is a code change and needs a full test run.
const SOLIDITY_VERSION = "0.8.38";

// Optional. Path to a local Solidity compiler (native binary or soljson.js),
// for machines that cannot reach the compiler download server. Leave unset
// everywhere else.
const localCompilerPath = process.env.ALLKA_SOLC_PATH;

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    version: SOLIDITY_VERSION,
    ...(localCompilerPath !== undefined ? { path: localCompilerPath } : {}),
    settings: {
      // Conflux eSpace follows Cancun-level opcodes since its v3.0 hardfork.
      // Re-check against the eSpace docs before every mainnet deployment.
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  test: {
    solidity: {
      profiles: {
        // What runs every time, locally and on every change pushed to GitHub.
        // failOnRevert: a step of a random sequence that fails without being
        // expected to fails the run, instead of being dropped silently.
        default: {
          invariant: { runs: 64, depth: 250, failOnRevert: true },
        },
        // The long run, before a release: npx hardhat test solidity --test-profile deep
        deep: {
          fuzz: { runs: 2_000 },
          invariant: { runs: 512, depth: 500, failOnRevert: true },
        },
      },
    },
  },
  // Publishing the source code on ConfluxScan, the explorer of Conflux eSpace,
  // so that anyone can read the contracts next to their addresses. ConfluxScan
  // asks for an API key but accepts any value (Conflux docs, "Verify
  // Contracts"): "espace" is a placeholder, not a secret. After a deployment:
  // npx hardhat ignition verify chain-71
  chainDescriptors: {
    71: {
      name: "Conflux eSpace Testnet",
      chainType: "generic",
      blockExplorers: {
        etherscan: {
          name: "ConfluxScan",
          url: "https://evmtestnet.confluxscan.org",
          apiUrl: "https://evmapi-testnet.confluxscan.org/api/",
        },
      },
    },
  },
  verify: {
    etherscan: { apiKey: "espace" },
    blockscout: { enabled: false },
    sourcify: { enabled: false },
  },
  // Only the test network is configured. Mainnet is left out on purpose until
  // the owner decides to go there: it will get its own key and its own
  // deployment module, so that a wrong --network cannot put a test deployment
  // on mainnet.
  networks: {
    confluxESpaceTestnet: {
      type: "http",
      chainType: "generic",
      chainId: 71,
      url: "https://evmtestnet.confluxrpc.com",
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
  },
});
