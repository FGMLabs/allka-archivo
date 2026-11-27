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

    /// @dev The test deployment starts with this token. If it can only exist on test networks, the same goes for
    /// everything that deployment creates. 1030 is Conflux eSpace mainnet and 1029 Conflux Core mainnet.
    function test_RevertWhen_DeployedOutsideTheTwoTestNetworks() public {
        uint256[6] memory chains = [uint256(1030), 1029, 1, 56, 70, 72];

        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            vm.expectRevert(abi.encodeWithSelector(TestUSDT0.OnlyForTestNetworks.selector, chains[i]));
            new TestUSDT0();
        }
    }

    /// @dev The testnet of Conflux eSpace (71) and the local simulated network (31337, where these tests run).
    function test_DeploysOnTheTwoTestNetworks() public {
        assertEq(block.chainid, 31337);
        assertEq(new TestUSDT0().totalSupply(), 0);

        vm.chainId(71);
        assertEq(new TestUSDT0().totalSupply(), 0);
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
