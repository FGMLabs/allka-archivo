import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { network } from "hardhat";
import { getAddress, type Hex } from "viem";

// The early window of a drop is opened with a snapshot: a Merkle tree of wallets. The admin panel will build that
// tree with OpenZeppelin's merkle-tree library, so this test builds one with the real library and checks that the
// sale contract accepts exactly the wallets in it. The Solidity tests build their trees by hand.

const usdt0 = (amount: number) => BigInt(amount) * 10n ** 6n;
const HOUR = 60 * 60;
const PRICE = usdt0(50);
const NO_STORAGE_FEE = { freePeriod: 0, feePerPeriod: 0n, maxFee: 0n };

describe("A snapshot built with OpenZeppelin's merkle-tree library", async function () {
  const { viem, networkHelpers } = await network.create();
  const wallets = await viem.getWalletClients();
  const [, admin, operator, treasury] = wallets;
  // Seven wallets in the snapshot: not a power of two, so the tree is not perfectly balanced.
  const inside = wallets.slice(4, 11);
  const outsider = wallets[11];

  const usdt = await viem.deployContract("TestUSDT0");
  const prenda = await viem.deployContract("Prenda", [
    "Allka Archivo",
    "ALLKA",
    usdt.address,
    treasury.account.address,
    admin.account.address,
    "",
  ]);
  const venta = await viem.deployContract("Venta", [prenda.address, operator.account.address, HOUR, usdt0(1), 0n]);
  await prenda.write.setMinter([venta.address, true], { account: admin.account });

  const snapshot = StandardMerkleTree.of(
    inside.map((wallet) => [getAddress(wallet.account.address)]),
    ["address"],
  );
  const proofOf = (wallet: (typeof wallets)[number]) => snapshot.getProof([getAddress(wallet.account.address)]) as Hex[];

  const earlyStart = (await networkHelpers.time.latest()) + 2 * HOUR;
  // One garment for each wallet of the snapshot and one more.
  const items = Array.from({ length: inside.length + 1 }, (_, i) => ({
    tokenId: BigInt(i + 1),
    price: PRICE,
    contentHash: `0x${(i + 1).toString(16).padStart(64, "0")}` as Hex,
  }));
  await venta.write.createDrop([earlyStart, earlyStart + 6 * HOUR, snapshot.root as Hex, NO_STORAGE_FEE, items], {
    account: operator.account,
  });
  await networkHelpers.time.increaseTo(earlyStart);

  async function fundAndApprove(buyer: (typeof wallets)[number]) {
    await usdt.write.mint([PRICE], { account: buyer.account });
    await usdt.write.approve([venta.address, PRICE], { account: buyer.account });
  }

  it("refuses a wallet of the snapshot that brings the proof of another wallet", async function () {
    await fundAndApprove(inside[0]);
    await viem.assertions.revertWithCustomErrorWithArgs(
      venta.write.buy([1n, 1, PRICE, proofOf(inside[1])], { account: inside[0].account }),
      venta,
      "NotInSnapshot",
      [getAddress(inside[0].account.address)],
    );
  });

  it("lets every wallet of the snapshot buy in the early window with its own proof", async function () {
    for (const [i, wallet] of inside.entries()) {
      await fundAndApprove(wallet);
      await venta.write.buy([BigInt(i + 1), 1, PRICE, proofOf(wallet)], { account: wallet.account });
      assert.equal(await prenda.read.ownerOf([BigInt(i + 1)]), getAddress(wallet.account.address));
    }
  });

  it("refuses a wallet outside the snapshot, whatever proof it brings", async function () {
    const lastGarment = BigInt(inside.length + 1);
    // A proof that is good in another snapshot, one that does contain the outsider, is no good here.
    const otherSnapshot = StandardMerkleTree.of(
      [[getAddress(outsider.account.address)], [getAddress(inside[0].account.address)]],
      ["address"],
    );
    const proofElsewhere = otherSnapshot.getProof([getAddress(outsider.account.address)]) as Hex[];
    assert.notEqual(otherSnapshot.root, snapshot.root);

    await fundAndApprove(outsider);
    for (const proof of [[], proofOf(inside[0]), proofOf(inside[6]), proofElsewhere]) {
      await viem.assertions.revertWithCustomErrorWithArgs(
        venta.write.buy([lastGarment, 1, PRICE, proof], { account: outsider.account }),
        venta,
        "NotInSnapshot",
        [getAddress(outsider.account.address)],
      );
    }
    assert.equal(await prenda.read.isTokenIdUsed([lastGarment]), false);
  });

  it("works with a snapshot of a single wallet, whose proof is empty", async function () {
    const [only, other] = [wallets[12], wallets[13]];
    const single = StandardMerkleTree.of([[getAddress(only.account.address)]], ["address"]);
    const emptyProof = single.getProof([getAddress(only.account.address)]) as Hex[];
    assert.equal(emptyProof.length, 0);

    const start = (await networkHelpers.time.latest()) + 2 * HOUR;
    const garments = [101n, 102n].map((tokenId) => ({
      tokenId,
      price: PRICE,
      contentHash: `0x${tokenId.toString(16).padStart(64, "0")}` as Hex,
    }));
    await venta.write.createDrop([start, start + 6 * HOUR, single.root as Hex, NO_STORAGE_FEE, garments], {
      account: operator.account,
    });
    const dropId = await venta.read.dropCount();
    await networkHelpers.time.increaseTo(start);

    await fundAndApprove(other);
    await viem.assertions.revertWithCustomErrorWithArgs(
      venta.write.buy([102n, dropId, PRICE, []], { account: other.account }),
      venta,
      "NotInSnapshot",
      [getAddress(other.account.address)],
    );
    await fundAndApprove(only);
    await venta.write.buy([101n, dropId, PRICE, emptyProof], { account: only.account });
    assert.equal(await prenda.read.ownerOf([101n]), getAddress(only.account.address));
  });
});
