// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSDT0
/// @notice Test-only stand-in for USDT0, for local tests and testnets.
/// @dev It copies USDT0's 6 decimals and nothing else. It has no value, no
///      blocklist and no upgradeability, so passing tests against this token
///      does not replace testing against the real USDT0 before mainnet.
///      Anyone can mint to themselves. It refuses to be deployed on Conflux
///      eSpace mainnet, so that the test deployment cannot land there by mistake.
contract TestUSDT0 is ERC20 {
    /// @notice Largest amount a single call to `mint` can create: 10,000 tokens.
    uint256 public constant MAX_MINT_PER_CALL = 10_000 * 10 ** 6;

    /// @notice Chain id of Conflux eSpace mainnet, where this token must never exist.
    uint256 public constant MAINNET_CHAIN_ID = 1030;

    /// @notice The requested amount is above `MAX_MINT_PER_CALL`.
    error MintTooLarge(uint256 requested, uint256 maximum);

    /// @notice Somebody tried to deploy the test token on mainnet.
    error NotForMainnet();

    constructor() ERC20("Test USDT0", "tUSDT0") {
        if (block.chainid == MAINNET_CHAIN_ID) revert NotForMainnet();
    }

    /// @notice USDT0 uses 6 decimals: 1 token is written as 1_000_000.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints `amount` test tokens to the caller.
    /// @param amount Amount in base units (6 decimals).
    function mint(uint256 amount) external {
        if (amount > MAX_MINT_PER_CALL) {
            revert MintTooLarge(amount, MAX_MINT_PER_CALL);
        }
        _mint(msg.sender, amount);
    }
}
