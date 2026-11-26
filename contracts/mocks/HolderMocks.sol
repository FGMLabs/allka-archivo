// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Prenda} from "../Prenda.sol";
import {IPaymentCallback} from "./PaymentTokenMocks.sol";

// Test helpers: holders that are contracts instead of ordinary wallets. Never deploy them to a real network.

/// @notice A contract with no functions at all. It cannot claim, approve or answer when it receives an NFT.
contract InertHolderMock {}

/// @notice A contract that accepts NFTs sent with `safeTransferFrom` and counts them.
contract AcceptingReceiverMock is IERC721Receiver {
    uint256 public received;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        received += 1;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice A contract that refuses NFTs sent with `safeTransferFrom`.
contract RejectingReceiverMock is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @notice A minimal smart-contract wallet: its owner makes it call anything.
contract WalletMock {
    address public immutable owner;

    error NotTheWalletOwner(address caller);

    constructor(address owner_) {
        owner = owner_;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != owner) revert NotTheWalletOwner(msg.sender);
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }
}

interface IMover {
    function move(address from, address to, uint256 tokenId) external;
}

/**
 * @notice A holder that tries to cheat while it claims: when the payment token calls it back in the middle of
 * paying the storage fee, it tries to sell the NFT it is claiming and to claim it a second time. If the NFT still
 * existed at that moment it would end up both sold and claimed.
 */
contract DoubleDipHolderMock is IPaymentCallback {
    Prenda public immutable prenda;
    IMover public immutable market;
    address public immutable accomplice;
    uint256 public tokenId;

    bool public callbackRan;
    bool public nftExistedDuringPayment;
    bool public resaleDuringPaymentWorked;
    bool public secondClaimDuringPaymentWorked;

    constructor(Prenda prenda_, IMover market_, address accomplice_) {
        prenda = prenda_;
        market = market_;
        accomplice = accomplice_;
    }

    function prepare(uint256 tokenId_, IERC20 paymentToken, uint256 allowance) external {
        tokenId = tokenId_;
        prenda.setApprovalForAll(address(market), true);
        paymentToken.approve(address(prenda), allowance);
    }

    function claim(uint256 maxFeeAccepted) external {
        prenda.claim(tokenId, maxFeeAccepted);
    }

    function onPayment() external {
        callbackRan = true;
        try prenda.ownerOf(tokenId) returns (address) {
            nftExistedDuringPayment = true;
        } catch {}
        try market.move(address(this), accomplice, tokenId) {
            resaleDuringPaymentWorked = true;
        } catch {}
        try prenda.claim(tokenId, type(uint256).max) {
            secondClaimDuringPaymentWorked = true;
        } catch {}
    }
}
