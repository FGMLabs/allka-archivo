// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Prenda} from "../Prenda.sol";

/**
 * @title OpenMinterMock
 * @notice Test helper. Stands in for a sale module: anyone can ask it to create an NFT, for free and with any
 * terms. It has no rules of its own, so every limit seen in the tests comes from the NFT contract. Never deploy it
 * to a real network.
 */
contract OpenMinterMock {
    Prenda public immutable prenda;

    constructor(Prenda prenda_) {
        prenda = prenda_;
    }

    function mint(address to, uint256 tokenId, Prenda.StorageTerms calldata terms, bytes32 contentHash) external {
        prenda.mint(to, tokenId, terms, contentHash);
    }
}
