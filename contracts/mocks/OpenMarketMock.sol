// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Prenda} from "../Prenda.sol";

/**
 * @title OpenMarketMock
 * @notice Test helper. Stands in for a market module, including one that misbehaves: anyone can ask it to move an
 * NFT or to hand an approval to somebody else. It has no rules of its own, so every limit seen in the tests comes
 * from the NFT contract. Never deploy it to a real network.
 */
contract OpenMarketMock {
    Prenda public immutable prenda;

    constructor(Prenda prenda_) {
        prenda = prenda_;
    }

    function move(address from, address to, uint256 tokenId) external {
        prenda.transferFrom(from, to, tokenId);
    }

    function safeMove(address from, address to, uint256 tokenId) external {
        prenda.safeTransferFrom(from, to, tokenId);
    }

    /// @dev The call a well-behaved market never makes: pass its permission over an NFT on to somebody else.
    function grant(address to, uint256 tokenId) external {
        prenda.approve(to, tokenId);
    }
}
