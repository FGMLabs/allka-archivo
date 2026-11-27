import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress } from "viem";

import TestnetModule from "../ignition/modules/Testnet.js";

// The deployment module for test networks, run on a simulated network: what it deploys, how it wires the
// contracts together and which values it uses when nobody says otherwise.

describe("The deployment module for test networks", async function () {
  it("deploys the four contracts and wires them with its default values", async function () {
    const { ignition, viem } = await network.create();
    const [deployer] = await viem.getWalletClients();
    const me = getAddress(deployer.account.address);

    const { usdt, prenda, venta, mercado } = await ignition.deploy(TestnetModule);

    // The deploying account is the administration, the treasury and the operator.
    assert.equal(getAddress(await prenda.read.owner()), me);
    assert.equal(getAddress(await prenda.read.treasury()), me);
    assert.equal(getAddress(await venta.read.operator()), me);
    assert.equal(await prenda.read.pauser(), "0x0000000000000000000000000000000000000000");

    // The three contracts use the test token and name the same NFT contract.
    assert.equal(getAddress(await prenda.read.paymentToken()), getAddress(usdt.address));
    assert.equal(getAddress(await venta.read.paymentToken()), getAddress(usdt.address));
    assert.equal(getAddress(await mercado.read.paymentToken()), getAddress(usdt.address));
    assert.equal(getAddress(await venta.read.prenda()), getAddress(prenda.address));
    assert.equal(getAddress(await mercado.read.prenda()), getAddress(prenda.address));

    // The sale module can create NFTs and the market can move them; not the other way round.
    assert.equal(await prenda.read.isMinter([venta.address]), true);
    assert.equal(await prenda.read.isMinter([mercado.address]), false);
    assert.equal(await prenda.read.marketStatus([mercado.address]), 1);
    assert.equal(await prenda.read.marketStatus([venta.address]), 0);
    assert.equal(await prenda.read.paused(), false);
    assert.equal(await prenda.read.transfersOpen(), false);

    assert.equal(await prenda.read.name(), "Allka Archivo (testnet)");
    assert.equal(await prenda.read.symbol(), "tALLKA");
    assert.equal(await usdt.read.decimals(), 6);
    // Drops can open ten minutes after they are loaded: a value for testing, never for mainnet.
    assert.equal(await venta.read.openingDelay(), 600);
    assert.equal(await venta.read.minPrice(), 1_000_000n);
    assert.equal(await venta.read.maxStorageFee(), 100_000_000n);
    assert.equal(await mercado.read.minPrice(), 1_000_000n);
    assert.equal(await mercado.read.MAX_LISTING_DURATION(), 30n * 24n * 60n * 60n);
  });

  it("takes the treasury, the operator and the opening delay from parameters", async function () {
    const { ignition, viem } = await network.create();
    const [deployer, treasury, operator] = await viem.getWalletClients();

    const { prenda, venta } = await ignition.deploy(TestnetModule, {
      parameters: {
        AllkaArchivoTestnet: {
          treasury: treasury.account.address,
          operator: operator.account.address,
          openingDelay: 3600,
        },
      },
    });

    assert.equal(getAddress(await prenda.read.treasury()), getAddress(treasury.account.address));
    assert.equal(getAddress(await venta.read.operator()), getAddress(operator.account.address));
    assert.equal(await venta.read.openingDelay(), 3600);
    // The administration is always the deploying account: the module has no parameter for it.
    assert.equal(getAddress(await prenda.read.owner()), getAddress(deployer.account.address));
  });
});
