# Allka Archivo — Version 1 architecture

Status: approved on 26 November 2026. Under construction (Phase 1: contracts). [Versión en español](ARQUITECTURA.md)

## In one sentence

A store with a built-in resale market where each one-of-a-kind allka garment is an NFT on Conflux eSpace. Everything is paid in USDT0. The physical garment is already made and stored, and it ships when the NFT's owner claims it.

## The parts

| Part | What it does |
|---|---|
| Garment contract (NFT) | The permanent contract. One NFT per physical garment, with its size. It keeps each drop's storage rules and handles the claim: claiming burns the NFT. |
| Sale contract | The drops: each garment with its own price in USDT0, opening date and early access for $FGM holders. It charges and delivers the NFT in the same step. |
| Market contract | Resale: the owner lists a price and another user buys. The payment is split on the spot: 98% to the seller, 2% to FGM. Offers expire. Nobody administers it. |
| Website | Next.js on Vercel, in English and Spanish, mobile first. Screens: drops, garment, market, my collection, claim. |
| Server and database | Holds the catalogue (photos, sizes) and the shipping and billing details, which are only requested at claim time. |
| Admin panel | Create drops without touching code, see the claims waiting to ship and mark shipments. |

Sale and Market are modules that can be added or replaced. The Garment contract is never replaced.

In the code the three contracts keep their Spanish names: `Prenda`, `Venta` and `Mercado`.

## How the money moves

- Primary sale: USDT0 goes straight from the buyer's wallet to the FGM treasury. There is no escrow and no contract ever holds funds.
- Resale: USDT0 goes straight from the buyer to the seller (98%) and to the treasury (2%). The fee is fixed in this Market: nobody can raise it.
- Storage: the free period counts from the original sale. After that, one instalment is added for every 30 full days, up to a maximum set in the drop. Whoever claims pays it. Example: with 6 free months, a claim made when 8 months are up pays 2 instalments; at 7 and a half months it pays 1. The right to the garment never expires.
- FGM can waive storage fees by giving a garment more free time. It can never raise them or shorten the free time.
- Storage is always charged in the same currency (USDT0). It cannot be switched to another one.

## Early access for $FGM holders

Before each drop, a snapshot records who holds $FGM. During the early window, each wallet in that snapshot can buy one garment. After that the drop opens to everyone. The snapshot stops the same $FGM from being passed between wallets to get in several times.

## Physical garments

Every garment is finished, tagged with its NFT number and stored before its drop goes on sale.

## The four journeys

1. Buy: connect the wallet, approve the exact USDT0 amount and buy. The buyer states the drop they saw the garment in and the price they expect to pay; if anything changed, the purchase does not go through.
2. Resell: the first time, the owner gives the Market permission over their NFTs; then they list a price and say until when the offer stands (30 days at most). When another user pays, the NFT changes owner. The buyer states the price they expect to pay; if the seller changed it, the purchase does not go through. An offer stops being valid when it expires, when the NFT changes hands, when the owner takes back from the Market the permission over all their NFTs (all their offers on that Market fall) or when the owner takes back the permission over that NFT (only that offer falls). It never comes back: to sell again, the owner lists again.
3. Claim: the site first checks that shipping to that country is possible and takes the shipping details, which are stored under an order number. The owner pays the storage fee if there is one and the NFT is burned naming that order number. The order is confirmed only from that on-chain burn. The details can be corrected until dispatch, with the signature of the same wallet that burned.
4. Create a drop: fill in the panel form, review the values the panel reads back and sign. The drop opens at least 24 hours later: the contract accepts no less, except on testnet, where a short delay is used for testing. Once created it cannot be changed, but it can be closed at any moment, before or after it opens: what was already sold stays sold, and what was not sold stops being on sale and can go into a new drop.

## Transfers

An NFT only changes owner through an authorised Market, and always with its owner's permission: no Market, current or future, can move an NFT its owner has not approved. There is a one-way switch to free transfers later.

Permissions are stricter than in an ordinary NFT, so that these rules do not depend on how each Market is written:

- Only the owner gives permissions. A Market cannot pass the permission it received on to another one.
- While transfers are closed, permission can only be given to an authorised Market. That way no permissions to third parties pile up waiting for the day transfers are freed.
- A Market that is switched off loses every permission it had.
- The contract counts the permissions that are taken back, in two counts: how many times an owner took back from somebody the permission over all their NFTs, and how many times the permission over one particular NFT was taken back from somebody. With those counts, the Market drops the offers that lost the permission they were made under, even if it is given again later.

Limits worth knowing: the lock does not stop someone from selling their whole wallet, and a user whose wallet is compromised cannot move the NFT to another one (they can only sell it or claim the garment).

## What FGM can do after selling

- Pause purchases and resale in an emergency. Claims are never paused. A day-to-day key that can do nothing else can pause too; only the admin can resume.
- Close a drop, before or after it opens. What was already sold is not affected.
- Add a new Sale module or retire one.
- Authorise a new Market or permanently switch off one that fails.
- Free transfers (cannot be undone).
- Propose a new treasury. The change only takes effect when the new treasury confirms it from its own wallet, so an address that nobody controls never receives the money. If the address is mistyped but belongs to somebody, that somebody could confirm it: it has to be checked before confirming.
- Waive storage fees, for one garment or for all of them at once, up to two years ahead each time. It can be renewed.
- Change the web address that serves the NFTs' photos and data. The content cannot change unnoticed: it is sealed with its content hash.

What it cannot do: change the price of a drop already created, raise its storage fee, change the currency it is charged in, move someone else's NFT, claim someone else's garment, or sell a used NFT number again.

## Security

- Four FGM addresses: operator (creates drops; cannot change where money goes), treasury (receives USDT0), admin (the switches listed above; kept offline and not used day to day) and pauser (can only pause).
- The contract rejects prices below a minimum and storage fees above a maximum, so a data-entry mistake cannot give a drop away.
- Contracts only charge the caller and never hold a balance.
- USDT0 is controlled by its issuer, which can block addresses and upgrade the token. That is why the treasury can be changed and a claim with no storage fee does not touch the token. Known limit: if the issuer blocked the address of the Garment contract, claims that owe a storage fee would stop until FGM waives it, which it can do for every garment in one step; claims with no fee keep working. Since each waiver reaches two years at most, while the block lasts it has to be renewed before it lapses (open decision before mainnet: whether a permanent way out is better). Before mainnet everything is tested against the real USDT0 on a fork of the network.
- Only Sale modules and Markets built for this contract can be added. The admin cannot register another address by mistake, or use the Market switch-off to block other people's wallets or contracts.
- The server ships only once the burn is final on chain (finalized).
- Personal data: the minimum, encrypted, admin panel behind two-factor login, deleted after delivery and never written on chain.
- Each NFT's photos and data are sealed with a content hash when the drop is created.
- Private keys never live in the repository.

## What a user needs in version 1

A wallet that works with Conflux eSpace (for example MetaMask, Fluent or OKX), USDT0 to pay and a few cents of CFX for gas.

## Stage 2 (after version 1)

Card payments through an NFT checkout provider, and email login, with no CFX needed by the user.

## What is still missing before mainnet

- An external audit of the contracts.
- Legal and tax review of the model, terms and conditions, and a privacy policy.

One consequence of the design worth keeping in mind: since the right to the garment never expires, the garment of someone who loses their wallet stays in storage forever.

## Phases

1. Contracts with their tests, including the paths that must fail, and testnet deployment.
2. Website: drops and purchase with USDT0.
3. Resale.
4. Claim and admin panel.
5. Internal security review and checklist.
6. External audit of the contracts. Only then, mainnet.

## When version 1 is done

On testnet and from a phone: two people buy with USDT0, resell an NFT between them, one claims the garment, and a new drop is created without touching code. The tests for what must not be possible also pass: buying at a different price, claiming someone else's NFT, moving an NFT outside the Market.
