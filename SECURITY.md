# Security

## Status

Allka Archivo is in early development.

- The contracts are **not audited**.
- Everything runs on **testnet only**. Nothing here is deployed to mainnet.
- Do not use this code with real funds.

An external audit of the contracts is a required step before any mainnet deployment.

## Reporting a problem

If you find a vulnerability, please do not open a public issue.

- Use GitHub's private vulnerability reporting on this repository (the "Report a vulnerability" button in the Security tab), or
- Send a direct message to [@FGMLabs](https://x.com/FGMLabs) on X.

Tell us what you found, how to reproduce it and what an attacker could do with it. We will answer as soon as we can.

## What the design tries to guarantee

These are the properties the tests and the future audit should hold the contracts to:

- No contract ever holds funds. Payments go straight from the buyer to the recipient.
- No Market, current or future, can move an NFT without its owner's approval.
- Only the owner of an NFT can claim its garment, and only the owner can give someone permission over it.
- The terms of a drop (price, storage rules) cannot be made worse for holders after it is created.
- A buyer names the drop and the price they saw. The purchase goes through only under those terms.
- A resale offer stops for good when it expires, when the NFT changes hands or when the seller takes the permission back from the Market. It never comes back to life.
- A burned NFT number is never sold again.
- Private keys never live in this repository.
