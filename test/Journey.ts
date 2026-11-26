import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { concat, encodeAbiParameters, getAddress, keccak256, type Hex } from "viem";

// The journey that defines when version 1 is done, on a simulated network: two people buy with USDT0, they resell
// an NFT between them, one claims the garment, and a new drop is loaded without touching code. It ends with the
// things that must not be possible.

const usdt0 = (amount: number) => BigInt(amount) * 10n ** 6n;

const HOUR = 60 * 60;
const DAY = 24 * HOUR;

const OPENING_DELAY = 24 * HOUR;
const EARLY_WINDOW = 6 * HOUR;
const MIN_PRICE = usdt0(10);
const MAX_STORAGE_FEE = usdt0(100);
const PRICE = usdt0(120);
const RESALE_PRICE = usdt0(200);
const STORAGE = { freePeriod: 180 * DAY, feePerPeriod: usdt0(5), maxFee: usdt0(30) };

/** Leaf of a wallet in a snapshot, as OpenZeppelin's merkle-tree library computes it. */
function leafOf(account: Hex): Hex {
  return keccak256(keccak256(encodeAbiParameters([{ type: "address" }], [account])));
}

function hashPair(a: Hex, b: Hex): Hex {
  return BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a]));
}

function fingerprintOf(tokenId: bigint): Hex {
  return keccak256(encodeAbiParameters([{ type: "string" }, { type: "uint256" }], ["data of garment", tokenId]));
}

describe("Version 1 journey", async function () {
  const { viem, networkHelpers } = await network.create();
  const [, admin, operator, treasury, alice, bob, carol] = await viem.getWalletClients();

  const address = {
    admin: getAddress(admin.account.address),
    operator: getAddress(operator.account.address),
    treasury: getAddress(treasury.account.address),
    alice: getAddress(alice.account.address),
    bob: getAddress(bob.account.address),
    carol: getAddress(carol.account.address),
  };

  // The deployer keeps no power: the administration is another account from the start.
  const usdt = await viem.deployContract("TestUSDT0");
  const prenda = await viem.deployContract("Prenda", [
    "Allka Archivo",
    "ALLKA",
    usdt.address,
    address.treasury,
    address.admin,
    "https://example.test/nft/",
  ]);
  const venta = await viem.deployContract("Venta", [
    prenda.address,
    address.operator,
    OPENING_DELAY,
    MIN_PRICE,
    MAX_STORAGE_FEE,
  ]);
  const mercado = await viem.deployContract("Mercado", [prenda.address, MIN_PRICE, 30 * DAY]);
  await prenda.write.setMinter([venta.address, true], { account: admin.account });
  await prenda.write.authorizeMarket([mercado.address], { account: admin.account });

  /** Gives `buyer` exactly `amount` test USDT0 and approves `spender` for exactly that amount. */
  async function fundAndApprove(buyer: typeof alice, spender: Hex, amount: bigint) {
    await usdt.write.mint([amount], { account: buyer.account });
    await usdt.write.approve([spender, amount], { account: buyer.account });
  }

  /** A moment a new drop can open at: the shortest delay allowed plus an hour of margin. */
  async function nextOpening() {
    return (await networkHelpers.time.latest()) + OPENING_DELAY + HOUR;
  }

  // The snapshot of the first drop has two wallets: alice and carol. Bob is not in it.
  const snapshotRoot = hashPair(leafOf(address.alice), leafOf(address.carol));
  const aliceProof = [leafOf(address.carol)];

  let earlyStart = 0;
  let publicStart = 0;

  it("the operator loads a drop that opens first for the snapshot", async function () {
    earlyStart = await nextOpening();
    publicStart = earlyStart + EARLY_WINDOW;

    await viem.assertions.emitWithArgs(
      venta.write.createDrop(
        [
          earlyStart,
          publicStart,
          snapshotRoot,
          STORAGE,
          [
            { tokenId: 1n, price: PRICE, contentHash: fingerprintOf(1n) },
            { tokenId: 2n, price: PRICE, contentHash: fingerprintOf(2n) },
          ],
        ],
        { account: operator.account },
      ),
      venta,
      "DropCreated",
      [1, earlyStart, publicStart, snapshotRoot, STORAGE.freePeriod, STORAGE.feePerPeriod, STORAGE.maxFee],
    );

    // Nobody can buy before the drop opens, not even a wallet of the snapshot.
    await fundAndApprove(alice, venta.address, PRICE);
    await viem.assertions.revertWithCustomError(
      venta.write.buy([1n, PRICE, aliceProof], { account: alice.account }),
      venta,
      "NotOpenYet",
    );
  });

  it("two people buy with USDT0: one in the early window, the other after it", async function () {
    await networkHelpers.time.increaseTo(earlyStart);

    // Bob is not in the snapshot: he has to wait.
    await fundAndApprove(bob, venta.address, PRICE);
    await viem.assertions.revertWithCustomErrorWithArgs(
      venta.write.buy([2n, PRICE, []], { account: bob.account }),
      venta,
      "NotInSnapshot",
      [address.bob],
    );

    await viem.assertions.emitWithArgs(
      venta.write.buy([1n, PRICE, aliceProof], { account: alice.account }),
      venta,
      "Purchased",
      [1, 1n, address.alice, PRICE, true],
    );

    await networkHelpers.time.increaseTo(publicStart);
    await viem.assertions.emitWithArgs(
      venta.write.buy([2n, PRICE, []], { account: bob.account }),
      venta,
      "Purchased",
      [1, 2n, address.bob, PRICE, false],
    );

    assert.equal(await prenda.read.ownerOf([1n]), address.alice);
    assert.equal(await prenda.read.ownerOf([2n]), address.bob);
    assert.equal(await prenda.read.contentHashOf([1n]), fingerprintOf(1n));
    // The money went straight to the treasury. No contract kept any of it.
    assert.equal(await usdt.read.balanceOf([address.treasury]), 2n * PRICE);
    assert.equal(await usdt.read.balanceOf([venta.address]), 0n);
    assert.equal(await usdt.read.balanceOf([prenda.address]), 0n);
    assert.equal(await usdt.read.balanceOf([address.alice]), 0n);
    assert.equal(await usdt.read.balanceOf([address.bob]), 0n);
  });

  it("they resell an NFT between them: 98% to the seller and 2% to the treasury", async function () {
    const expiresAt = (await networkHelpers.time.latest()) + 7 * DAY;
    await prenda.write.setApprovalForAll([mercado.address, true], { account: alice.account });
    await mercado.write.list([1n, RESALE_PRICE, expiresAt], { account: alice.account });

    await fundAndApprove(bob, mercado.address, RESALE_PRICE);
    await viem.assertions.emitWithArgs(
      mercado.write.buy([1n, RESALE_PRICE], { account: bob.account }),
      mercado,
      "Sold",
      [1n, address.alice, address.bob, RESALE_PRICE, usdt0(4)],
    );

    assert.equal(await prenda.read.ownerOf([1n]), address.bob);
    assert.equal(await prenda.read.transferCountOf([1n]), 1);
    assert.equal(await usdt.read.balanceOf([address.alice]), usdt0(196));
    assert.equal(await usdt.read.balanceOf([address.treasury]), 2n * PRICE + usdt0(4));
    assert.equal(await usdt.read.balanceOf([mercado.address]), 0n);
    assert.equal(await usdt.read.balanceOf([address.bob]), 0n);
  });

  it("the buyer claims the garment: the NFT is burned and its number is never sold again", async function () {
    // Still inside the free storage period: the claim costs nothing and needs no USDT0 approval.
    assert.equal(await prenda.read.storageFeeOf([1n]), 0n);
    await viem.assertions.emitWithArgs(prenda.write.claim([1n, 0n], { account: bob.account }), prenda, "Claimed", [
      1n,
      address.bob,
      0n,
    ]);

    await viem.assertions.revertWithCustomError(prenda.read.ownerOf([1n]), prenda, "ERC721NonexistentToken");
    assert.equal(await prenda.read.isTokenIdUsed([1n]), true);
    assert.equal(await prenda.read.contentHashOf([1n]), fingerprintOf(1n));

    const start = await nextOpening();
    await viem.assertions.revertWithCustomErrorWithArgs(
      venta.write.createDrop(
        [start, start, `0x${"00".repeat(32)}`, STORAGE, [{ tokenId: 1n, price: PRICE, contentHash: fingerprintOf(1n) }]],
        { account: operator.account },
      ),
      venta,
      "TokenIdNotAvailable",
      [1n],
    );
  });

  it("a garment kept past the free period pays the storage fee when it is claimed", async function () {
    const [freeUntil] = await prenda.read.storageTermsOf([2n]);
    await networkHelpers.time.increaseTo(freeUntil + 65 * DAY);

    // 65 days after the free period: two full periods of 30 days, two instalments of 5 USDT0.
    assert.equal(await prenda.read.storageFeeOf([2n]), usdt0(10));
    const treasuryBefore = await usdt.read.balanceOf([address.treasury]);
    await fundAndApprove(bob, prenda.address, usdt0(10));
    await prenda.write.claim([2n, usdt0(10)], { account: bob.account });

    assert.equal(await usdt.read.balanceOf([address.treasury]), treasuryBefore + usdt0(10));
    assert.equal(await usdt.read.balanceOf([prenda.address]), 0n);
    assert.equal(await prenda.read.balanceOf([address.bob]), 0n);
  });

  it("a new drop is loaded without touching code, and it sells", async function () {
    const start = await nextOpening();
    await venta.write.createDrop(
      [
        start,
        start,
        `0x${"00".repeat(32)}`,
        { freePeriod: 90 * DAY, feePerPeriod: 0n, maxFee: 0n },
        [
          { tokenId: 10n, price: usdt0(80), contentHash: fingerprintOf(10n) },
          { tokenId: 11n, price: usdt0(95), contentHash: fingerprintOf(11n) },
        ],
      ],
      { account: operator.account },
    );
    assert.equal(await venta.read.dropCount(), 2);

    await networkHelpers.time.increaseTo(start);
    await fundAndApprove(carol, venta.address, usdt0(95));
    await venta.write.buy([11n, usdt0(95), []], { account: carol.account });

    assert.equal(await prenda.read.ownerOf([11n]), address.carol);
  });

  it("what must not be possible is not possible", async function () {
    // Buying at another price.
    await fundAndApprove(alice, venta.address, usdt0(80));
    await viem.assertions.revertWithCustomErrorWithArgs(
      venta.write.buy([10n, usdt0(79), []], { account: alice.account }),
      venta,
      "PriceNotAsExpected",
      [10n, usdt0(80), usdt0(79)],
    );

    // Claiming somebody else's NFT: not a stranger, not the administration, not the operator.
    for (const intruder of [alice, admin, operator]) {
      await viem.assertions.revertWithCustomErrorWithArgs(
        prenda.write.claim([11n, 0n], { account: intruder.account }),
        prenda,
        "NotTokenHolder",
        [11n, getAddress(intruder.account.address)],
      );
    }

    // Moving an NFT outside the market: not even its holder can.
    await viem.assertions.revertWithCustomErrorWithArgs(
      prenda.write.transferFrom([address.carol, address.alice, 11n], { account: carol.account }),
      prenda,
      "TransferNotAllowed",
      [address.carol],
    );
    await viem.assertions.revertWithCustomErrorWithArgs(
      prenda.write.approve([address.alice, 11n], { account: carol.account }),
      prenda,
      "ApprovalNotAllowed",
      [address.alice],
    );

    // The market cannot move an NFT whose holder did not approve it, whoever asks.
    await viem.assertions.revertWithCustomError(
      mercado.write.list([11n, usdt0(50), (await networkHelpers.time.latest()) + DAY], { account: alice.account }),
      mercado,
      "NotHolder",
    );

    // Somebody who is not the operator loading a drop, or somebody who is not the administration pausing.
    const start = await nextOpening();
    await viem.assertions.revertWithCustomError(
      venta.write.createDrop(
        [start, start, `0x${"00".repeat(32)}`, STORAGE, [{ tokenId: 20n, price: PRICE, contentHash: fingerprintOf(20n) }]],
        { account: alice.account },
      ),
      venta,
      "NotOperator",
    );
    await viem.assertions.revertWithCustomError(
      prenda.write.pause({ account: operator.account }),
      prenda,
      "OwnableUnauthorizedAccount",
    );

    assert.equal(await prenda.read.ownerOf([11n]), address.carol);
  });
});
