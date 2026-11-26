# Allka Archivo

The working rules for this repository are in [CLAUDE.md](CLAUDE.md) (in Spanish). Read that file, [ESTADO.md](ESTADO.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before making changes.

## Project layout

```
contracts/        Solidity source files (*.sol) and unit tests (*.t.sol)
test/             TypeScript integration tests
ignition/         Hardhat Ignition deployment modules
docs/             Architecture, in Spanish and English
hardhat.config.ts Compiler, EVM target and networks
```

## Working in this project

- `npx hardhat build` compiles, `npx hardhat test` runs every test and `npx tsc --noEmit` type-checks.
- The compiler version, the EVM target and the optimizer settings are pinned in `hardhat.config.ts`. Changing them is a code change.
- Private keys never go in the repository.
- When writing tests or touching the Hardhat configuration, use the Hardhat guides in `.claude/skills/`.

## Docs

- Hardhat 3: https://hardhat.org/llms.txt
- viem: https://viem.sh/llms.txt
