// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Test helpers: contracts that answer the question "which NFT contract were you built for?" in a wrong way, even
// though the answer contains the right address. Never deploy them to a real network.

/// @notice Fails on every call, and the data of the failure is the address it was given.
contract FailingAnswerMock {
    bytes32 private immutable _answer;

    constructor(address named) {
        _answer = bytes32(uint256(uint160(named)));
    }

    fallback() external {
        bytes32 answer = _answer;
        assembly ("memory-safe") {
            mstore(0x00, answer)
            revert(0x00, 0x20)
        }
    }
}

/// @notice Answers every call with the address it was given followed by a second word.
contract LongAnswerMock {
    bytes32 private immutable _answer;

    constructor(address named) {
        _answer = bytes32(uint256(uint160(named)));
    }

    fallback() external {
        bytes32 answer = _answer;
        assembly ("memory-safe") {
            mstore(0x00, answer)
            mstore(0x20, 1)
            return(0x00, 0x40)
        }
    }
}

/// @notice Answers every call with one word: the address it was given, with a bit set above the address.
contract DirtyAnswerMock {
    bytes32 private immutable _answer;

    constructor(address named) {
        _answer = bytes32(uint256(uint160(named)) | (1 << 255));
    }

    fallback() external {
        bytes32 answer = _answer;
        assembly ("memory-safe") {
            mstore(0x00, answer)
            return(0x00, 0x20)
        }
    }
}
