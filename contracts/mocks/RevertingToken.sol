// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/**
 * @title RevertingToken
 * @notice Test helper. A payment token that fails on every call, like a token that was frozen or broken by its
 * issuer. It proves which operations never touch the payment token. Never deploy it to a real network.
 */
contract RevertingToken {
    error PaymentTokenWasCalled();

    fallback() external {
        revert PaymentTokenWasCalled();
    }
}
