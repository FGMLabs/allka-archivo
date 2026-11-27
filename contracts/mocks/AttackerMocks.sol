// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mercado} from "../Mercado.sol";
import {Prenda} from "../Prenda.sol";
import {Venta} from "../Venta.sol";
import {OpenMarketMock} from "./OpenMarketMock.sol";
import {ITransferHook} from "./PaymentTokenMocks.sol";

// Test helpers: a seller and a buyer that are contracts and try everything they can when the payment token hands
// them control in the middle of a purchase (see HookTokenMock). Never deploy them to a real network.

/// @notice Offers an NFT on the market and, while it is being paid for it, does one thing of its choice.
contract SellerAttackerMock is ITransferHook {
    enum Action {
        None,
        Claim,
        Relist,
        Revoke,
        MoveAway,
        MoveAwayAndBack,
        Cancel
    }

    Prenda public immutable prenda;
    Mercado public immutable mercado;
    OpenMarketMock public immutable otherMarket;
    address public immutable accomplice;

    uint256 public tokenId;
    Action public action;
    uint8 public phase;

    bool public hookRan;
    bool public actionWorked;
    bytes public actionError;
    address public holderSeenInHook;
    uint256 public balanceSeenInHook;

    constructor(Prenda prenda_, Mercado mercado_, OpenMarketMock otherMarket_, address accomplice_) {
        prenda = prenda_;
        mercado = mercado_;
        otherMarket = otherMarket_;
        accomplice = accomplice_;
    }

    /// @dev Approves both markets and offers the NFT.
    function prepare(uint256 tokenId_, uint80 price, uint48 expiresAt) external {
        tokenId = tokenId_;
        prenda.setApprovalForAll(address(mercado), true);
        prenda.setApprovalForAll(address(otherMarket), true);
        mercado.list(tokenId_, price, expiresAt);
    }

    /// @dev What to do, and at which moment of the payment (see ITransferHook).
    function arm(Action action_, uint8 phase_) external {
        action = action_;
        phase = phase_;
    }

    function moveAwayAndBack() external {
        require(msg.sender == address(this), "only self");
        otherMarket.move(address(this), accomplice, tokenId);
        otherMarket.move(accomplice, address(this), tokenId);
    }

    function onTokenHook(uint8 phase_) external {
        if (phase_ != phase || hookRan) return;
        hookRan = true;
        holderSeenInHook = prenda.ownerOf(tokenId);
        balanceSeenInHook = IERC20(msg.sender).balanceOf(address(this));

        if (action == Action.Claim) {
            try prenda.claim(tokenId, type(uint256).max, bytes32(0)) {
                actionWorked = true;
            } catch (bytes memory reason) {
                actionError = reason;
            }
        } else if (action == Action.Relist) {
            try mercado.list(tokenId, 10 * 10 ** 6, uint48(block.timestamp + 1 days)) {
                actionWorked = true;
            } catch (bytes memory reason) {
                actionError = reason;
            }
        } else if (action == Action.Revoke) {
            try prenda.setApprovalForAll(address(mercado), false) {
                actionWorked = true;
            } catch (bytes memory reason) {
                actionError = reason;
            }
        } else if (action == Action.MoveAway) {
            try otherMarket.move(address(this), accomplice, tokenId) {
                actionWorked = true;
            } catch (bytes memory reason) {
                actionError = reason;
            }
        } else if (action == Action.MoveAwayAndBack) {
            try this.moveAwayAndBack() {
                actionWorked = true;
            } catch (bytes memory reason) {
                actionError = reason;
            }
        } else if (action == Action.Cancel) {
            try mercado.cancel(tokenId) {
                actionWorked = true;
            } catch (bytes memory reason) {
                actionError = reason;
            }
        }
    }
}

/**
 * @notice Buys in the first sale or on the market and, while it pays, tries to buy the same thing again, to buy
 * another garment, to claim the garment and to offer it for sale.
 */
contract BuyerAttackerMock is ITransferHook {
    Prenda public immutable prenda;
    Venta public immutable venta;
    Mercado public immutable mercado;
    IERC20 public immutable token;

    uint8 public phase;
    bool public onMarket;
    uint32 public dropId;
    uint256 public targetTokenId;
    uint256 public targetPrice;
    uint256 public otherTokenId;
    uint256 public otherPrice;
    bytes32[] public proof;

    bool public hookRan;
    bool public nftExistedInHook;
    address public holderSeenInHook;
    bool public sameAgainWorked;
    bool public otherWorked;
    bool public claimWorked;
    bool public listWorked;

    constructor(Prenda prenda_, Venta venta_, Mercado mercado_, IERC20 token_) {
        prenda = prenda_;
        venta = venta_;
        mercado = mercado_;
        token = token_;
    }

    /// @dev At which moment of the payment to act (see ITransferHook).
    function arm(uint8 phase_) external {
        phase = phase_;
    }

    function approveMarket() external {
        prenda.setApprovalForAll(address(mercado), true);
    }

    function buyFromVenta(
        uint256 tokenId,
        uint32 dropId_,
        uint256 price,
        bytes32[] calldata proof_,
        uint256 otherTokenId_,
        uint256 otherPrice_
    ) external {
        onMarket = false;
        dropId = dropId_;
        targetTokenId = tokenId;
        targetPrice = price;
        otherTokenId = otherTokenId_;
        otherPrice = otherPrice_;
        proof = proof_;
        token.approve(address(venta), 2 * price + otherPrice_);
        venta.buy(tokenId, dropId_, price, proof_);
    }

    function buyFromMercado(uint256 tokenId, uint256 price) external {
        onMarket = true;
        targetTokenId = tokenId;
        targetPrice = price;
        token.approve(address(mercado), 2 * price);
        mercado.buy(tokenId, price);
    }

    function onTokenHook(uint8 phase_) external {
        if (phase_ != phase || hookRan) return;
        hookRan = true;
        try prenda.ownerOf(targetTokenId) returns (address holder) {
            nftExistedInHook = true;
            holderSeenInHook = holder;
        } catch {}

        if (onMarket) {
            try mercado.buy(targetTokenId, targetPrice) {
                sameAgainWorked = true;
            } catch {}
        } else {
            try venta.buy(targetTokenId, dropId, targetPrice, proof) {
                sameAgainWorked = true;
            } catch {}
            try venta.buy(otherTokenId, dropId, otherPrice, proof) {
                otherWorked = true;
            } catch {}
        }
        try prenda.claim(targetTokenId, type(uint256).max, bytes32(0)) {
            claimWorked = true;
        } catch {}
        try mercado.list(targetTokenId, 10 * 10 ** 6, uint48(block.timestamp + 1 days)) {
            listWorked = true;
        } catch {}
    }
}
