// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title OpenMarketMock
 * @notice Test helper. Stands in for a market contract: anyone can ask it to move an NFT. It has no rules of its
 * own, so every limit seen in the tests comes from the NFT contract. Never deploy it to a real network.
 */
contract OpenMarketMock {
    IERC721 public immutable nft;

    constructor(IERC721 nft_) {
        nft = nft_;
    }

    function move(address from, address to, uint256 tokenId) external {
        nft.transferFrom(from, to, tokenId);
    }

    function safeMove(address from, address to, uint256 tokenId) external {
        nft.safeTransferFrom(from, to, tokenId);
    }
}
