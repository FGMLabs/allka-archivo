// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Test helpers: payment tokens that behave in ways the real USDT0 could. Never deploy them to a real network.

/**
 * @notice Payment token with a block list, shaped after what the OpenZeppelin audit of USDT0 (29 January 2025)
 * describes: a blocked account cannot have its tokens moved and cannot carry out transfers for others, but it can
 * still receive. This is a model, NOT the real USDT0: the real contract has to be tested on a fork of the network.
 */
contract BlocklistTokenMock is ERC20 {
    mapping(address account => bool) public isBlocked;

    error Blocked(address account);

    constructor() ERC20("Blocklist USDT0", "bUSDT0") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool blocked) external {
        isBlocked[account] = blocked;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (isBlocked[msg.sender]) revert Blocked(msg.sender);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (isBlocked[msg.sender]) revert Blocked(msg.sender);
        if (isBlocked[from]) revert Blocked(from);
        return super.transferFrom(from, to, value);
    }
}

interface IPaymentCallback {
    function onPayment() external;
}

/**
 * @notice Payment token that calls the payer, if it is a contract, right before its tokens move (as ERC-777 tokens
 * did). USDT0 does not do this today, but its issuer can upgrade it. Used to look at the NFT contract in the
 * middle of a paid claim.
 */
contract CallbackTokenMock is ERC20 {
    constructor() ERC20("Callback USDT0", "cUSDT0") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (from.code.length != 0) IPaymentCallback(from).onPayment();
        return super.transferFrom(from, to, value);
    }
}

interface ITransferHook {
    /// @dev `phase` 1: the payer, before the tokens move. 2: the receiver, before. 3: the payer, after. 4: the
    /// receiver, after.
    function onTokenHook(uint8 phase) external;
}

/**
 * @notice Payment token that calls the payer and the receiver, before and after the tokens move, when they asked
 * for it. It stands for the worst an upgrade of USDT0 could do to a purchase: hand control to either side in the
 * middle of it.
 */
contract HookTokenMock is ERC20 {
    mapping(address account => bool) public hooked;

    constructor() ERC20("Hook USDT0", "hUSDT0") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHooked(address account, bool on) external {
        hooked[account] = on;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool ok) {
        if (hooked[from]) ITransferHook(from).onTokenHook(1);
        if (hooked[to]) ITransferHook(to).onTokenHook(2);
        ok = super.transferFrom(from, to, value);
        if (hooked[from]) ITransferHook(from).onTokenHook(3);
        if (hooked[to]) ITransferHook(to).onTokenHook(4);
    }
}

/// @notice Old-style payment token: when the payer cannot pay it answers false instead of failing.
contract FalseReturningTokenMock {
    mapping(address account => uint256) public balanceOf;
    mapping(address holder => mapping(address spender => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (balanceOf[from] < value || allowance[from][msg.sender] < value) return false;
        balanceOf[from] -= value;
        allowance[from][msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }
}
