import { network } from "hardhat";
import { keccak256, toHex } from "viem";

import TestnetModule from "../ignition/modules/Testnet.js";

// Loads a small test drop into the system deployed with ignition/modules/Testnet.ts, so that there is something to
// buy while trying the contracts on a test network. Run it with the account that deployed, which is the operator:
//
//   npx hardhat run scripts/create-test-drop.ts --network confluxESpaceTestnet
//
// The drop has three garments at 5 test USDT0 each, with no early window, and opens as soon as the sale contract
// allows (ten minutes after loading, with the default values of the test deployment).

const GARMENTS = 3;
const PRICE = 5_000_000n; // 5 test USDT0: the token has 6 decimals
const DAY = 24 * 60 * 60;
// Free storage for 30 days, then 1 test USDT0 for every 30 days, 3 at most.
const STORAGE = { freePeriod: 30 * DAY, feePerPeriod: 1_000_000n, maxFee: 3_000_000n };
const NO_SNAPSHOT = `0x${"00".repeat(32)}` as const;

const { ignition, viem } = await network.create();
const publicClient = await viem.getPublicClient();

// On a network where the module was already deployed this does not deploy again: it returns the same contracts.
const { venta } = await ignition.deploy(TestnetModule);

const dropsSoFar = await venta.read.dropCount();
const openingDelay = await venta.read.openingDelay();
const now = (await publicClient.getBlock()).timestamp;
// Two minutes of margin over the shortest delay allowed, for the time the transaction takes to be included.
const start = Number(now) + Number(openingDelay) + 120;

// Garment numbers that no earlier test drop used: 101 to 103 for the first drop, 201 to 203 for the second...
const firstId = BigInt(dropsSoFar + 1) * 100n + 1n;
const items = Array.from({ length: GARMENTS }, (_, i) => ({
  tokenId: firstId + BigInt(i),
  price: PRICE,
  contentHash: keccak256(toHex(`test garment ${firstId + BigInt(i)}`)),
}));

const hash = await venta.write.createDrop([start, start, NO_SNAPSHOT, STORAGE, items]);
await publicClient.waitForTransactionReceipt({ hash });

console.log(`Drop ${dropsSoFar + 1} loaded in the sale contract ${venta.address}`);
console.log(`  garments: ${items.map((item) => item.tokenId).join(", ")}`);
console.log(`  price of each: ${PRICE} units (5 test USDT0)`);
console.log(`  opens at: ${new Date(start * 1000).toLocaleString()} (${start})`);
console.log(`  transaction: ${hash}`);
