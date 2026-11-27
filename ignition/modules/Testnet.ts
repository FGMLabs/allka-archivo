import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys the whole system to a TEST network and wires it together: the test token, the NFT contract, the sale
 * module and the market.
 *
 * Never use this module on mainnet. It deploys a test token that anyone can mint, and the account that deploys is
 * also the administration. On mainnet the token is the real USDT0 and the administration is a separate account
 * kept offline. As a safety net, the test token refuses to be deployed on Conflux eSpace mainnet, and it is the
 * first thing this module deploys.
 *
 * Every value has a default made for testing from a phone: drops can open ten minutes after they are created
 * instead of 24 hours later. The treasury and the operator are the deploying account unless a parameters file
 * says otherwise.
 */
export default buildModule("AllkaArchivoTestnet", (m) => {
  const deployer = m.getAccount(0);

  const treasury = m.getParameter("treasury", deployer);
  const operator = m.getParameter("operator", deployer);
  const name = m.getParameter("name", "Allka Archivo (testnet)");
  const symbol = m.getParameter("symbol", "tALLKA");
  const baseURI = m.getParameter("baseURI", "");

  // Amounts are in units of the test token, which has 6 decimals like USDT0: 1_000_000 is 1 USDT0.
  const openingDelay = m.getParameter("openingDelay", 10 * 60);
  const minPrice = m.getParameter("minPrice", 1_000_000n);
  const maxStorageFee = m.getParameter("maxStorageFee", 100_000_000n);
  const marketMinPrice = m.getParameter("marketMinPrice", 1_000_000n);

  const usdt = m.contract("TestUSDT0");
  const prenda = m.contract("Prenda", [name, symbol, usdt, treasury, deployer, baseURI]);
  const venta = m.contract("Venta", [prenda, operator, openingDelay, minPrice, maxStorageFee]);
  const mercado = m.contract("Mercado", [prenda, marketMinPrice]);

  // The administration, which here is the deploying account, allows the sale module to create NFTs and the market
  // to move the NFTs their holders approve.
  m.call(prenda, "setMinter", [venta, true], { from: deployer });
  m.call(prenda, "authorizeMarket", [mercado], { from: deployer });

  return { usdt, prenda, venta, mercado };
});
