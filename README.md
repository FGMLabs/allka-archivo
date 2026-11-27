# Allka Archivo

Physical fashion pieces sold as NFTs on Conflux eSpace, with a built-in resale market. Built by FGM Labs for [allka](https://allka.com.ar).

> **Status:** early development. Phase 1 (smart contracts) is in progress. Testnet only. Not audited. Do not use with real funds.

[Leer en español](README.es.md)

## What it is

Each one-of-a-kind allka garment is an NFT. The NFT is the right to claim the physical piece, which is already made and stored.

1. **Primary sale.** Buy a garment's NFT with USDT0.
2. **Resale market.** List an unclaimed NFT at your price; another user buys it on the same site.
3. **Claim.** Give your shipping details, burn the NFT and receive the garment.

## How it is built

| Part | Role |
|---|---|
| `Prenda` | The NFT contract. One NFT per physical garment. Keeps each drop's storage rules and handles the claim. |
| `Venta` | The drops: price in USDT0, opening date, early access for $FGM holders. |
| `Mercado` | Resale between users, with a fixed 2% fee. |
| Website | Next.js and TypeScript, in English and Spanish, mobile first (later phase). |

The rules the contracts enforce:

- Everything is paid in USDT0. No contract ever holds funds: payments go straight from the buyer to the recipient.
- An NFT only changes owner through the Market, and always with its owner's approval.
- The resale fee is fixed at 2% and cannot be raised.
- Storage is free for a period; after that a monthly fee accrues up to a cap and is paid when claiming. The right to the garment never expires.
- $FGM holders get early access to drops, based on a snapshot taken before each drop.
- Every garment is finished, tagged with its NFT number and stored before its drop goes on sale.

The full design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Roadmap

- [x] Phase 0. Architecture and an independent security review of the design.
- [ ] Phase 1. Contracts with their tests, and testnet deployment.
- [ ] Phase 2. Website: drops and purchase with USDT0.
- [ ] Phase 3. Resale.
- [ ] Phase 4. Claim and admin panel.
- [ ] Phase 5. Internal security review and checklist.
- [ ] Phase 6. External audit. Only then, mainnet.

After version 1: card payments through an NFT checkout provider, and email login.

## Run it locally

You need Node.js 22.13 or later.

```bash
npm install
npx hardhat test
```

That runs every test: unit and fuzz tests of each contract, random sequences of operations over the three contracts together, and the full version 1 journey. The long run, with many more random cases, is:

```bash
npx hardhat test solidity --test-profile deep
```

## Stack

Solidity 0.8.38, OpenZeppelin Contracts 5.6, Hardhat 3 and Conflux eSpace (testnet chain ID 71, mainnet chain ID 1030).

## Security

The contracts are not audited. See [SECURITY.md](SECURITY.md) for the current status and how to report a problem.

## How this project is developed

The code is written with Claude (Anthropic) acting as the technical team, phase by phase, under the product owner's review. The working rules are in [CLAUDE.md](CLAUDE.md) and the project log, in Spanish, is in [ESTADO.md](ESTADO.md).

## Links

- FGM Labs on X: [@FGMLabs](https://x.com/FGMLabs)
- allka: [allka.com.ar](https://allka.com.ar)

## License

[MIT](LICENSE)
