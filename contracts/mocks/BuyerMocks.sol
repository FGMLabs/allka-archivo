// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mercado} from "../Mercado.sol";
import {Venta} from "../Venta.sol";
import {IPaymentCallback} from "./PaymentTokenMocks.sol";

// Test helpers: buyers that are contracts and try to cheat when the payment token calls them back in the middle of
// a purchase. Never deploy them to a real network.

/// @notice Buys a garment in the first sale and, from inside the payment, tries to buy a second time.
contract ReentrantSaleBuyerMock is IPaymentCallback {
    Venta public immutable venta;

    uint256 public secondTokenId;
    uint256 public secondPrice;
    bytes32[] public secondProof;

    bool public callbackRan;
    bool public secondPurchaseWorked;

    constructor(Venta venta_) {
        venta = venta_;
    }

    function buy(
        IERC20 paymentToken,
        uint256 tokenId,
        uint256 price,
        bytes32[] calldata proof,
        uint256 secondTokenId_,
        uint256 secondPrice_
    ) external {
        secondTokenId = secondTokenId_;
        secondPrice = secondPrice_;
        secondProof = proof;
        paymentToken.approve(address(venta), price + secondPrice_);
        venta.buy(tokenId, price, proof);
    }

    function onPayment() external {
        if (callbackRan) return;
        callbackRan = true;
        try venta.buy(secondTokenId, secondPrice, secondProof) {
            secondPurchaseWorked = true;
        } catch {}
    }
}

/// @notice Buys an NFT on the market and, from inside the payment, tries to buy the same offer again.
contract ReentrantMarketBuyerMock is IPaymentCallback {
    Mercado public immutable mercado;

    uint256 public tokenId;
    uint256 public price;

    bool public callbackRan;
    bool public secondPurchaseWorked;

    constructor(Mercado mercado_) {
        mercado = mercado_;
    }

    function buy(IERC20 paymentToken, uint256 tokenId_, uint256 price_) external {
        tokenId = tokenId_;
        price = price_;
        paymentToken.approve(address(mercado), 2 * price_);
        mercado.buy(tokenId_, price_);
    }

    function onPayment() external {
        if (callbackRan) return;
        callbackRan = true;
        try mercado.buy(tokenId, price) {
            secondPurchaseWorked = true;
        } catch {}
    }
}
