// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSDT0
/// @notice Test-only stand-in for USDT0, for local tests and testnets.
/// @dev It copies USDT0's 6 decimals and nothing else. It has no value, no
///      blocklist and no upgradeability, so passing tests against this token
///      does not replace testing against the real USDT0 before mainnet.
///      Anyone can mint to themselves. It can only be deployed on the testnet
///      of Conflux eSpace and on a local simulated network, so that the test
///      deployment, which starts with this token, cannot land anywhere else.
contract TestUSDT0 is ERC20 {
    /// @notice Largest amount a single call to `mint` can create: 10,000 tokens.
    uint256 public constant MAX_MINT_PER_CALL = 10_000 * 10 ** 6;

    /// @dev The two networks this token can exist on: the testnet of Conflux eSpace and the local simulated
    /// network of the development tools.
    uint256 private constant CONFLUX_ESPACE_TESTNET = 71;
    uint256 private constant LOCAL_SIMULATED_NETWORK = 31337;

    /// @notice The requested amount is above `MAX_MINT_PER_CALL`.
    error MintTooLarge(uint256 requested, uint256 maximum);

    /// @notice Somebody tried to deploy the test token on a network that is not a test network.
    error OnlyForTestNetworks(uint256 chainId);

    constructor() ERC20("Test USDT0", "tUSDT0") {
        if (block.chainid != CONFLUX_ESPACE_TESTNET && block.chainid != LOCAL_SIMULATED_NETWORK) {
            revert OnlyForTestNetworks(block.chainid);
        }
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
