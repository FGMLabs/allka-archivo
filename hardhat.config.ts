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
  networks: {
    confluxESpaceTestnet: {
      type: "http",
      chainType: "generic",
      chainId: 71,
      url: "https://evmtestnet.confluxrpc.com",
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
    confluxESpace: {
      type: "http",
      chainType: "generic",
      chainId: 1030,
      url: "https://evm.confluxrpc.com",
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
  },
});
