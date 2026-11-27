// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {TestUSDT0} from "./TestUSDT0.sol";

contract TestUSDT0Test is Test {
    TestUSDT0 internal token;
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new TestUSDT0();
    }

    function test_HasSixDecimalsLikeUSDT0() public view {
        assertEq(token.decimals(), 6);
    }

    /// @dev The test deployment starts with this token. If it cannot exist on mainnet, neither can the rest.
    function test_RevertWhen_DeployedOnConfluxESpaceMainnet() public {
        vm.chainId(1030);
        vm.expectRevert(TestUSDT0.NotForMainnet.selector);
        new TestUSDT0();

        // The testnet of Conflux eSpace is fine.
        vm.chainId(71);
        new TestUSDT0();
    }

    function test_StartsWithNoSupply() public view {
        assertEq(token.totalSupply(), 0);
    }

    function test_MintGoesToTheCaller() public {
        vm.prank(alice);
        token.mint(150 * 10 ** 6);

        assertEq(token.balanceOf(alice), 150 * 10 ** 6);
        assertEq(token.totalSupply(), 150 * 10 ** 6);
    }

    function test_MintAtTheMaximumWorks() public {
        uint256 maximum = token.MAX_MINT_PER_CALL();

        vm.prank(alice);
        token.mint(maximum);

        assertEq(token.balanceOf(alice), maximum);
    }

    function test_RevertWhen_MintIsAboveTheMaximum() public {
        uint256 maximum = token.MAX_MINT_PER_CALL();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestUSDT0.MintTooLarge.selector, maximum + 1, maximum));
        token.mint(maximum + 1);
    }

    function testFuzz_MintNeverCreatesMoreThanAsked(uint256 amount) public {
        amount = bound(amount, 0, token.MAX_MINT_PER_CALL());

        vm.prank(alice);
        token.mint(amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);
    }
}
