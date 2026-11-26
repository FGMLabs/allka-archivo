// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Prenda} from "./Prenda.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {RevertingToken} from "./mocks/RevertingToken.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

contract PrendaTest is Test {
    // A garment with 180 days of free storage, then 5 USDT0 for every 30 days, 30 USDT0 at most.
    uint32 internal constant FREE_PERIOD = 180 days;
    uint80 internal constant FEE = 5 * 10 ** 6;
    uint80 internal constant MAX_FEE = 30 * 10 ** 6;
    bytes32 internal constant CONTENT_HASH = keccak256("data of garment 1");
    uint256 internal constant TOKEN = 1;
    string internal constant BASE_URI = "https://example.test/nft/";

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    OpenMarketMock internal market;

    /// @dev Moment of the sale in every test: tokens are minted without moving the clock first.
    uint256 internal soldAt;

    /// @dev This test contract plays the role of the sale module: the administration makes it a minter.
    function setUp() public {
        usdt = new TestUSDT0();
        prenda = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, BASE_URI);
        market = new OpenMarketMock(prenda);

        vm.startPrank(admin);
        prenda.setMinter(address(this), true);
        prenda.authorizeMarket(address(market));
        vm.stopPrank();

        soldAt = block.timestamp;
    }

    function _terms() internal pure returns (Prenda.StorageTerms memory) {
        return Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: MAX_FEE});
    }

    function _sell(address to, uint256 tokenId) internal {
        prenda.mint(to, tokenId, _terms(), CONTENT_HASH);
    }

    /// @dev Gives `account` exactly `amount` test USDT0 and approves the NFT contract for exactly that amount.
    function _fundAndApprove(address account, uint256 amount) internal {
        vm.startPrank(account);
        usdt.mint(amount);
        usdt.approve(address(prenda), amount);
        vm.stopPrank();
    }

    function _approveMarket(address holder) internal {
        vm.prank(holder);
        prenda.setApprovalForAll(address(market), true);
    }

    function _unauthorized(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account);
    }

    function _nonexistent(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function test_DeploymentRecordsTheSetup() public view {
        assertEq(prenda.name(), "Allka Archivo");
        assertEq(prenda.symbol(), "ALLKA");
        assertEq(address(prenda.paymentToken()), address(usdt));
        assertEq(prenda.treasury(), treasury);
        assertEq(prenda.owner(), admin);
        assertEq(prenda.STORAGE_PERIOD(), 30 days);
        assertFalse(prenda.transfersOpen());
        assertFalse(prenda.paused());
    }

    function test_DeployerKeepsNoPower() public {
        Prenda fresh = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, BASE_URI);

        assertFalse(fresh.isMinter(address(this)));
        vm.expectRevert(_unauthorized(address(this)));
        fresh.pause();
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, address(this)));
        fresh.mint(alice, TOKEN, _terms(), CONTENT_HASH);
    }

    function test_RevertWhen_PaymentTokenIsNotAContract() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotAContract.selector, address(0)));
        new Prenda("Allka Archivo", "ALLKA", IERC20(address(0)), treasury, admin, BASE_URI);

        vm.expectRevert(abi.encodeWithSelector(Prenda.NotAContract.selector, stranger));
        new Prenda("Allka Archivo", "ALLKA", IERC20(stranger), treasury, admin, BASE_URI);
    }

    function test_RevertWhen_TreasuryIsZeroAtDeployment() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidTreasury.selector, address(0)));
        new Prenda("Allka Archivo", "ALLKA", usdt, address(0), admin, BASE_URI);
    }

    function test_RevertWhen_AdminIsZeroAtDeployment() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Prenda("Allka Archivo", "ALLKA", usdt, treasury, address(0), BASE_URI);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Creating an NFT (first sale)
    // ------------------------------------------------------------------------------------------------------------

    function test_MintCreatesTheNftWithItsStorageTermsAndFingerprint() public {
        vm.expectEmit(address(prenda));
        emit IERC721.Transfer(address(0), alice, TOKEN);
        vm.expectEmit(address(prenda));
        emit Prenda.Minted(TOKEN, alice, uint48(soldAt + FREE_PERIOD), FEE, MAX_FEE, CONTENT_HASH);
        _sell(alice, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.balanceOf(alice), 1);
        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, soldAt + FREE_PERIOD);
        assertEq(feePerPeriod, FEE);
        assertEq(maxFee, MAX_FEE);
        assertEq(prenda.contentHashOf(TOKEN), CONTENT_HASH);
        assertEq(prenda.transferCountOf(TOKEN), 0);
        assertTrue(prenda.isTokenIdUsed(TOKEN));
        assertEq(prenda.storageFeeOf(TOKEN), 0);
    }

    function test_UnusedTokenIdHasNoRecord() public view {
        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, 0);
        assertEq(feePerPeriod, 0);
        assertEq(maxFee, 0);
        assertEq(prenda.contentHashOf(TOKEN), bytes32(0));
        assertEq(prenda.transferCountOf(TOKEN), 0);
        assertFalse(prenda.isTokenIdUsed(TOKEN));
    }

    function test_MintWithoutStorageFeeIsAllowed() public {
        prenda.mint(alice, TOKEN, Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}), CONTENT_HASH);

        vm.warp(soldAt + 3650 days);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
    }

    function test_MintAcceptsTheLongestFreePeriod() public {
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: type(uint32).max, feePerPeriod: FEE, maxFee: MAX_FEE}),
            CONTENT_HASH
        );

        (uint48 freeUntil, , ) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, soldAt + type(uint32).max);
    }

    function test_MintAcceptsACeilingOfExactlyOneInstalment() public {
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: FEE}),
            CONTENT_HASH
        );

        vm.warp(soldAt + FREE_PERIOD + 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
        vm.warp(soldAt + FREE_PERIOD + 300 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
    }

    function test_RevertWhen_MintCallerIsNotAMinter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, stranger));
        prenda.mint(stranger, TOKEN, _terms(), CONTENT_HASH);
    }

    function test_RevertWhen_AdminMintsDirectly() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, admin));
        prenda.mint(admin, TOKEN, _terms(), CONTENT_HASH);
    }

    function test_RevertWhen_MinterWasRemoved() public {
        vm.prank(admin);
        prenda.setMinter(address(this), false);

        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, address(this)));
        _sell(alice, TOKEN);
    }

    function test_RevertWhen_MintWhilePaused() public {
        vm.prank(admin);
        prenda.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _sell(alice, TOKEN);
    }

    function test_RevertWhen_MintReusesATokenId() public {
        _sell(alice, TOKEN);

        vm.expectRevert(abi.encodeWithSelector(Prenda.TokenIdAlreadyUsed.selector, TOKEN));
        _sell(bob, TOKEN);
    }

    function test_RevertWhen_MintReusesABurnedTokenId() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.claim(TOKEN, 0);

        vm.expectRevert(abi.encodeWithSelector(Prenda.TokenIdAlreadyUsed.selector, TOKEN));
        _sell(bob, TOKEN);
    }

    function test_RevertWhen_ContentHashIsEmpty() public {
        vm.expectRevert(Prenda.EmptyContentHash.selector);
        prenda.mint(alice, TOKEN, _terms(), bytes32(0));
    }

    function test_RevertWhen_StorageHasNoFeeButHasACeiling() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidStorageTerms.selector, uint80(0), MAX_FEE));
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: 0, maxFee: MAX_FEE}),
            CONTENT_HASH
        );
    }

    function test_RevertWhen_StorageCeilingIsBelowOneInstalment() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidStorageTerms.selector, FEE, FEE - 1));
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: FEE - 1}),
            CONTENT_HASH
        );
    }

    function test_RevertWhen_StorageHasAFeeButNoCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidStorageTerms.selector, FEE, uint80(0)));
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: 0}),
            CONTENT_HASH
        );
    }

    function test_RevertWhen_MintToTheZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        _sell(address(0), TOKEN);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Storage fee
    // ------------------------------------------------------------------------------------------------------------

    function test_StorageIsFreeDuringTheFreePeriod() public {
        _sell(alice, TOKEN);

        assertEq(prenda.storageFeeOf(TOKEN), 0);
        vm.warp(soldAt + FREE_PERIOD / 2);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
        vm.warp(soldAt + FREE_PERIOD);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
    }

    function test_StorageIsStillFreeOneSecondBeforeTheFirstInstalment() public {
        _sell(alice, TOKEN);

        vm.warp(soldAt + FREE_PERIOD + 30 days - 1);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
    }

    function test_OneInstalmentAfterThirtyFullDays() public {
        _sell(alice, TOKEN);

        vm.warp(soldAt + FREE_PERIOD + 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
        vm.warp(soldAt + FREE_PERIOD + 60 days - 1);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
    }

    function test_TwoInstalmentsAfterSixtyFiveDays() public {
        _sell(alice, TOKEN);

        vm.warp(soldAt + FREE_PERIOD + 65 days);
        assertEq(prenda.storageFeeOf(TOKEN), 2 * uint256(FEE));
    }

    function test_StorageFeeStopsAtTheCeiling() public {
        _sell(alice, TOKEN);

        // The sixth instalment reaches the ceiling exactly.
        vm.warp(soldAt + FREE_PERIOD + 180 days);
        assertEq(prenda.storageFeeOf(TOKEN), MAX_FEE);
        vm.warp(soldAt + FREE_PERIOD + 210 days);
        assertEq(prenda.storageFeeOf(TOKEN), MAX_FEE);
        vm.warp(soldAt + 36500 days);
        assertEq(prenda.storageFeeOf(TOKEN), MAX_FEE);
    }

    function test_StorageFeeStopsAtACeilingThatIsNotAMultipleOfTheInstalment() public {
        uint80 ceiling = 12 * 10 ** 6;
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: ceiling}),
            CONTENT_HASH
        );

        vm.warp(soldAt + FREE_PERIOD + 60 days);
        assertEq(prenda.storageFeeOf(TOKEN), 10 * 10 ** 6);
        vm.warp(soldAt + FREE_PERIOD + 90 days);
        assertEq(prenda.storageFeeOf(TOKEN), ceiling);
    }

    function test_StorageFeeFollowsTheNftNotTheHolder() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.warp(soldAt + FREE_PERIOD + 30 days);

        market.move(alice, bob, TOKEN);

        // The free period is counted from the first sale, not from the resale.
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
    }

    function test_RevertWhen_AskingTheStorageFeeOfAnNftThatDoesNotExist() public {
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.storageFeeOf(TOKEN);

        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.claim(TOKEN, 0);

        vm.expectRevert(_nonexistent(TOKEN));
        prenda.storageFeeOf(TOKEN);
    }

    function testFuzz_StorageFeeMatchesTheRuleAndNeverGoesDown(
        uint32 freePeriod,
        uint80 feePerPeriod,
        uint80 maxFee,
        uint40 firstWait,
        uint40 secondWait
    ) public {
        feePerPeriod = uint80(bound(feePerPeriod, 1, type(uint80).max));
        maxFee = uint80(bound(maxFee, feePerPeriod, type(uint80).max));
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: freePeriod, feePerPeriod: feePerPeriod, maxFee: maxFee}),
            CONTENT_HASH
        );

        uint256 firstMoment = soldAt + firstWait;
        vm.warp(firstMoment);
        uint256 firstFee = prenda.storageFeeOf(TOKEN);
        assertEq(firstFee, _expectedFee(soldAt + freePeriod, feePerPeriod, maxFee, firstMoment));

        uint256 secondMoment = firstMoment + secondWait;
        vm.warp(secondMoment);
        uint256 secondFee = prenda.storageFeeOf(TOKEN);
        assertEq(secondFee, _expectedFee(soldAt + freePeriod, feePerPeriod, maxFee, secondMoment));

        assertLe(firstFee, secondFee);
        assertLe(secondFee, maxFee);
    }

    /// @dev The storage rule written a second time, on purpose in a different way: instalment by instalment.
    function _expectedFee(
        uint256 freeUntil,
        uint256 feePerPeriod,
        uint256 maxFee,
        uint256 moment
    ) internal pure returns (uint256) {
        if (moment < freeUntil + 30 days) return 0;
        uint256 instalments = 1 + (moment - freeUntil - 30 days) / 30 days;
        if (instalments > maxFee / feePerPeriod) return maxFee;
        return instalments * feePerPeriod;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Claiming the garment
    // ------------------------------------------------------------------------------------------------------------

    function test_FreeClaimBurnsTheNftAndMovesNoMoney() public {
        _sell(alice, TOKEN);

        vm.expectEmit(address(prenda));
        emit IERC721.Transfer(alice, address(0), TOKEN);
        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, alice, 0);
        vm.prank(alice);
        prenda.claim(TOKEN, 0);

        vm.expectRevert(_nonexistent(TOKEN));
        prenda.ownerOf(TOKEN);
        assertEq(prenda.balanceOf(alice), 0);
        assertEq(usdt.totalSupply(), 0);
        assertEq(usdt.balanceOf(treasury), 0);
    }

    function test_FreeClaimNeedsNoTokenApproval() public {
        _sell(alice, TOKEN);
        assertEq(usdt.allowance(alice, address(prenda)), 0);

        vm.prank(alice);
        prenda.claim(TOKEN, type(uint256).max);

        assertEq(prenda.balanceOf(alice), 0);
    }

    function test_FreeClaimNeverCallsThePaymentToken() public {
        Prenda frozen = _prendaWithBrokenToken();
        frozen.mint(alice, TOKEN, _terms(), CONTENT_HASH);

        vm.prank(alice);
        frozen.claim(TOKEN, 0);

        assertEq(frozen.balanceOf(alice), 0);
    }

    function test_RevertWhen_PaidClaimAndThePaymentTokenFails() public {
        Prenda frozen = _prendaWithBrokenToken();
        frozen.mint(alice, TOKEN, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 30 days);

        vm.prank(alice);
        vm.expectRevert(RevertingToken.PaymentTokenWasCalled.selector);
        frozen.claim(TOKEN, FEE);

        // Nothing happened: the NFT is still hers.
        assertEq(frozen.ownerOf(TOKEN), alice);
    }

    function test_FreeStorageExtensionUnblocksAClaimWhenThePaymentTokenFails() public {
        Prenda frozen = _prendaWithBrokenToken();
        frozen.mint(alice, TOKEN, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 30 days);

        vm.prank(admin);
        frozen.extendFreeStorage(TOKEN, uint48(block.timestamp));

        vm.prank(alice);
        frozen.claim(TOKEN, 0);
        assertEq(frozen.balanceOf(alice), 0);
    }

    function _prendaWithBrokenToken() internal returns (Prenda frozen) {
        IERC20 broken = IERC20(address(new RevertingToken()));
        frozen = new Prenda("Allka Archivo", "ALLKA", broken, treasury, admin, BASE_URI);
        vm.prank(admin);
        frozen.setMinter(address(this), true);
    }

    function test_PaidClaimSendsTheFeeFromTheClaimerToTheTreasury() public {
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 65 days);
        uint256 fee = 2 * uint256(FEE);
        _fundAndApprove(alice, fee);

        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, alice, fee);
        vm.prank(alice);
        prenda.claim(TOKEN, fee);

        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(treasury), fee);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(usdt.allowance(alice, address(prenda)), 0);
        assertEq(prenda.balanceOf(alice), 0);
    }

    function test_PaidClaimTakesOnlyTheFeeWhenMoreWasApproved() public {
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        _fundAndApprove(alice, 100 * 10 ** 6);

        vm.prank(alice);
        prenda.claim(TOKEN, 100 * 10 ** 6);

        assertEq(usdt.balanceOf(alice), 100 * 10 ** 6 - FEE);
        assertEq(usdt.balanceOf(treasury), FEE);
        assertEq(usdt.balanceOf(address(prenda)), 0);
    }

    function test_PaidClaimGoesToTheTreasuryInForceAtThatMoment() public {
        address newTreasury = makeAddr("new treasury");
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        _fundAndApprove(alice, FEE);

        vm.prank(admin);
        prenda.setTreasury(newTreasury);
        vm.prank(alice);
        prenda.claim(TOKEN, FEE);

        assertEq(usdt.balanceOf(newTreasury), FEE);
        assertEq(usdt.balanceOf(treasury), 0);
    }

    function test_ClaimWorksWhilePaused() public {
        _sell(alice, TOKEN);
        _sell(bob, TOKEN + 1);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        _fundAndApprove(bob, FEE);
        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN, uint48(block.timestamp));
        vm.prank(admin);
        prenda.pause();

        // One free claim and one paid claim, both with the contract paused.
        vm.prank(alice);
        prenda.claim(TOKEN, 0);
        vm.prank(bob);
        prenda.claim(TOKEN + 1, FEE);

        assertEq(prenda.balanceOf(alice), 0);
        assertEq(prenda.balanceOf(bob), 0);
        assertEq(usdt.balanceOf(treasury), FEE);
    }

    function test_ClaimKeepsTheRecordOfTheGarment() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.claim(TOKEN, 0);

        assertEq(prenda.contentHashOf(TOKEN), CONTENT_HASH);
        assertTrue(prenda.isTokenIdUsed(TOKEN));
    }

    function test_BuyerOnTheMarketCanClaimAndTheSellerCannot() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        market.move(alice, bob, TOKEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, alice));
        prenda.claim(TOKEN, 0);

        vm.prank(bob);
        prenda.claim(TOKEN, 0);
        assertEq(prenda.balanceOf(bob), 0);
    }

    function test_RevertWhen_ClaimerIsNotTheHolder() public {
        _sell(alice, TOKEN);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, stranger));
        prenda.claim(TOKEN, type(uint256).max);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_AnApprovedMarketClaims() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);

        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, address(market)));
        prenda.claim(TOKEN, type(uint256).max);
    }

    function test_RevertWhen_AdminOrMinterClaimsSomebodyElsesNft() public {
        _sell(alice, TOKEN);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, admin));
        prenda.claim(TOKEN, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, address(this)));
        prenda.claim(TOKEN, type(uint256).max);
    }

    function test_RevertWhen_ClaimingAnNftThatDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.claim(TOKEN, type(uint256).max);
    }

    function test_RevertWhen_ClaimingTwice() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.claim(TOKEN, 0);

        vm.expectRevert(_nonexistent(TOKEN));
        prenda.claim(TOKEN, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_StorageFeeIsAboveWhatTheClaimerAccepted() public {
        _sell(alice, TOKEN);
        _fundAndApprove(alice, 2 * uint256(FEE));

        // She signs when one instalment is due, and the transaction lands after the second one was added.
        vm.warp(soldAt + FREE_PERIOD + 60 days);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Prenda.StorageFeeAboveAccepted.selector, TOKEN, 2 * uint256(FEE), uint256(FEE))
        );
        prenda.claim(TOKEN, FEE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(alice), 2 * uint256(FEE));
    }

    function test_RevertWhen_ClaimerDidNotApproveTheFee() public {
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        vm.prank(alice);
        usdt.mint(FEE);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(prenda), 0, FEE)
        );
        prenda.claim(TOKEN, FEE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(alice), FEE);
    }

    function test_RevertWhen_ClaimerCannotPayTheFee() public {
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        vm.prank(alice);
        usdt.approve(address(prenda), FEE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, FEE));
        prenda.claim(TOKEN, FEE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function testFuzz_ClaimChargesExactlyTheStorageFeeAndKeepsNothing(
        uint32 freePeriod,
        uint80 feePerPeriod,
        uint80 maxFee,
        uint40 wait
    ) public {
        feePerPeriod = uint80(bound(feePerPeriod, 1, 100 * 10 ** 6));
        maxFee = uint80(bound(maxFee, feePerPeriod, 1000 * 10 ** 6));
        prenda.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: freePeriod, feePerPeriod: feePerPeriod, maxFee: maxFee}),
            CONTENT_HASH
        );
        vm.warp(soldAt + wait);
        uint256 fee = prenda.storageFeeOf(TOKEN);
        _fundAndApprove(alice, maxFee);

        vm.prank(alice);
        prenda.claim(TOKEN, fee);

        assertLe(fee, maxFee);
        assertEq(usdt.balanceOf(treasury), fee);
        assertEq(usdt.balanceOf(alice), maxFee - fee);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(prenda.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Transfers while they are closed
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_HolderTransfersDirectly() public {
        _sell(alice, TOKEN);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, alice));
        prenda.transferFrom(alice, bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, alice));
        prenda.safeTransferFrom(alice, bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, alice));
        prenda.safeTransferFrom(alice, bob, TOKEN, "");
        vm.stopPrank();

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_ApprovingSomeoneWhoIsNotAMarket() public {
        _sell(alice, TOKEN);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, bob));
        prenda.approve(bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, bob));
        prenda.setApprovalForAll(bob, true);
        vm.stopPrank();
    }

    function test_RevertWhen_AMarketThatWasNeverAuthorizedMoves() public {
        OpenMarketMock rogue = new OpenMarketMock(prenda);
        _sell(alice, TOKEN);

        // The holder cannot even approve it...
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, address(rogue)));
        prenda.setApprovalForAll(address(rogue), true);

        // ...and it cannot move anything.
        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, address(rogue)));
        rogue.move(alice, bob, TOKEN);
    }

    function test_AuthorizedMarketMovesAnNftItsHolderApproved() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.expectEmit(address(prenda));
        emit IERC721.Transfer(alice, bob, TOKEN);
        market.move(alice, bob, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), bob);
        assertEq(prenda.balanceOf(alice), 0);
        assertEq(prenda.balanceOf(bob), 1);
        assertEq(prenda.transferCountOf(TOKEN), 1);
    }

    function test_AuthorizedMarketMovesWithAnApprovalForOneNft() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);

        market.safeMove(alice, bob, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), bob);

        // The approval covered that NFT only.
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN + 1)
        );
        market.move(alice, bob, TOKEN + 1);
    }

    function test_RevertWhen_AuthorizedMarketMovesAnNftItsHolderDidNotApprove() public {
        _sell(alice, TOKEN);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN)
        );
        market.move(alice, bob, TOKEN);
    }

    /// @dev The central guarantee: authorizing a market gives it no power over NFTs that already exist.
    function test_RevertWhen_NewlyAuthorizedMarketMovesExistingNfts() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        OpenMarketMock newMarket = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(newMarket));

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(newMarket), TOKEN)
        );
        newMarket.move(alice, bob, TOKEN);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(newMarket), TOKEN)
        );
        newMarket.move(alice, address(newMarket), TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_MarketMovesFromTheWrongHolder() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, bob, TOKEN, alice));
        market.move(bob, stranger, TOKEN);
    }

    function test_RevertWhen_AdminMovesSomebodyElsesNft() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, admin));
        prenda.transferFrom(alice, admin, TOKEN);
    }

    function test_RevertWhen_MarketApprovalForOneNftIsReusedAfterTheSale() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);
        market.move(alice, bob, TOKEN);

        // The approval alice gave ended with the transfer: the market cannot take the NFT from bob.
        assertEq(prenda.getApproved(TOKEN), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN)
        );
        market.move(bob, alice, TOKEN);
    }

    function test_TransferCountGoesUpWithEveryChangeOfHands() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        _approveMarket(bob);

        market.move(alice, bob, TOKEN);
        market.move(bob, alice, TOKEN);
        market.move(alice, bob, TOKEN);

        assertEq(prenda.transferCountOf(TOKEN), 3);
        assertEq(prenda.transferCountOf(TOKEN + 1), 0);
    }

    function test_RevertWhen_MarketMovesWhilePaused() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(admin);
        prenda.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.move(alice, bob, TOKEN);

        vm.prank(admin);
        prenda.unpause();
        market.move(alice, bob, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Disabled markets
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_DisabledMarketMoves() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(admin);
        prenda.disableMarket(address(market));

        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, address(market)));
        market.move(alice, bob, TOKEN);
    }

    function test_RevertWhen_ApprovingADisabledMarket() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.disableMarket(address(market));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, address(market)));
        prenda.setApprovalForAll(address(market), true);
        vm.expectRevert(abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, address(market)));
        prenda.approve(address(market), TOKEN);
        vm.stopPrank();
    }

    function test_HolderCanAlwaysRevokeAnApproval() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);
        vm.prank(admin);
        prenda.disableMarket(address(market));

        vm.startPrank(alice);
        prenda.setApprovalForAll(address(market), false);
        prenda.approve(address(0), TOKEN);
        vm.stopPrank();

        assertFalse(prenda.isApprovedForAll(alice, address(market)));
        assertEq(prenda.getApproved(TOKEN), address(0));
    }

    function test_RevertWhen_DisabledMarketMovesAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.startPrank(admin);
        prenda.disableMarket(address(market));
        prenda.openTransfers();
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, address(market)));
        market.move(alice, bob, TOKEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, address(market)));
        prenda.approve(address(market), TOKEN);
    }

    function test_RevertWhen_MarketIsDisabledAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.startPrank(admin);
        prenda.openTransfers();
        prenda.disableMarket(address(market));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, address(market)));
        market.move(alice, bob, TOKEN);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Transfers once they are open
    // ------------------------------------------------------------------------------------------------------------

    function test_AfterOpeningHoldersTransferDirectly() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();

        vm.prank(alice);
        prenda.transferFrom(alice, bob, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), bob);
        assertEq(prenda.transferCountOf(TOKEN), 1);
    }

    function test_AfterOpeningAnyApprovedOperatorCanMove() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();
        vm.prank(alice);
        prenda.approve(stranger, TOKEN);

        vm.prank(stranger);
        prenda.safeTransferFrom(alice, bob, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_AfterOpeningHoldersCanApproveAnyOperator() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();

        vm.prank(alice);
        prenda.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        prenda.transferFrom(alice, bob, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_AfterOpeningTheAuthorizedMarketKeepsWorking() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(admin);
        prenda.openTransfers();

        market.move(alice, bob, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_SomeoneWithoutApprovalMovesAfterOpening() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, TOKEN));
        prenda.transferFrom(alice, stranger, TOKEN);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, admin, TOKEN));
        prenda.transferFrom(alice, admin, TOKEN);
    }

    function test_RevertWhen_HolderTransfersWhilePausedAfterOpening() public {
        _sell(alice, TOKEN);
        vm.startPrank(admin);
        prenda.openTransfers();
        prenda.pause();
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        prenda.transferFrom(alice, bob, TOKEN);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_SomeoneElseUsesTheAdministrationSwitches() public {
        _sell(alice, TOKEN);
        address[3] memory callers = [stranger, alice, address(this)];

        for (uint256 i = 0; i < callers.length; i++) {
            address caller = callers[i];
            bytes memory expected = _unauthorized(caller);
            vm.startPrank(caller);

            vm.expectRevert(expected);
            prenda.setMinter(address(market), true);
            vm.expectRevert(expected);
            prenda.authorizeMarket(address(usdt));
            vm.expectRevert(expected);
            prenda.disableMarket(address(market));
            vm.expectRevert(expected);
            prenda.openTransfers();
            vm.expectRevert(expected);
            prenda.setTreasury(caller);
            vm.expectRevert(expected);
            prenda.extendFreeStorage(TOKEN, type(uint48).max);
            vm.expectRevert(expected);
            prenda.setBaseURI("https://elsewhere.test/");
            vm.expectRevert(expected);
            prenda.pause();
            vm.expectRevert(expected);
            prenda.unpause();
            vm.expectRevert(expected);
            prenda.transferOwnership(caller);

            vm.stopPrank();
        }
    }

    function test_SetMinterAllowsAndStopsAModule() public {
        vm.startPrank(admin);
        vm.expectEmit(address(prenda));
        emit Prenda.MinterSet(address(market), true);
        prenda.setMinter(address(market), true);
        assertTrue(prenda.isMinter(address(market)));

        vm.expectEmit(address(prenda));
        emit Prenda.MinterSet(address(market), false);
        prenda.setMinter(address(market), false);
        assertFalse(prenda.isMinter(address(market)));
        vm.stopPrank();
    }

    function test_RevertWhen_MinterIsNotAContract() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotAContract.selector, stranger));
        prenda.setMinter(stranger, true);
    }

    function test_AuthorizeAndDisableAMarket() public {
        OpenMarketMock other = new OpenMarketMock(prenda);
        assertEq(uint8(prenda.marketStatus(address(other))), uint8(Prenda.MarketStatus.None));

        vm.startPrank(admin);
        vm.expectEmit(address(prenda));
        emit Prenda.MarketAuthorized(address(other));
        prenda.authorizeMarket(address(other));
        assertEq(uint8(prenda.marketStatus(address(other))), uint8(Prenda.MarketStatus.Authorized));

        vm.expectEmit(address(prenda));
        emit Prenda.MarketDisabled(address(other));
        prenda.disableMarket(address(other));
        assertEq(uint8(prenda.marketStatus(address(other))), uint8(Prenda.MarketStatus.Disabled));
        vm.stopPrank();
    }

    function test_RevertWhen_MarketIsNotAContract() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotAContract.selector, stranger));
        prenda.authorizeMarket(stranger);
    }

    function test_RevertWhen_AuthorizingAMarketTwice() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.MarketAlreadyRegistered.selector, address(market)));
        prenda.authorizeMarket(address(market));
    }

    function test_RevertWhen_AuthorizingADisabledMarketAgain() public {
        vm.startPrank(admin);
        prenda.disableMarket(address(market));

        vm.expectRevert(abi.encodeWithSelector(Prenda.MarketAlreadyRegistered.selector, address(market)));
        prenda.authorizeMarket(address(market));
        vm.stopPrank();
    }

    function test_RevertWhen_DisablingAMarketThatIsNotAuthorized() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.MarketNotAuthorized.selector, stranger));
        prenda.disableMarket(stranger);

        prenda.disableMarket(address(market));
        vm.expectRevert(abi.encodeWithSelector(Prenda.MarketNotAuthorized.selector, address(market)));
        prenda.disableMarket(address(market));
        vm.stopPrank();
    }

    function test_OpenTransfersWorksOnce() public {
        vm.startPrank(admin);
        vm.expectEmit(address(prenda));
        emit Prenda.TransfersOpened();
        prenda.openTransfers();
        assertTrue(prenda.transfersOpen());

        vm.expectRevert(Prenda.TransfersAlreadyOpen.selector);
        prenda.openTransfers();
        vm.stopPrank();
    }

    function test_SetTreasury() public {
        address newTreasury = makeAddr("new treasury");

        vm.expectEmit(address(prenda));
        emit Prenda.TreasuryChanged(treasury, newTreasury);
        vm.prank(admin);
        prenda.setTreasury(newTreasury);

        assertEq(prenda.treasury(), newTreasury);
    }

    function test_RevertWhen_NewTreasuryIsZeroOrTheContractItself() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidTreasury.selector, address(0)));
        prenda.setTreasury(address(0));
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidTreasury.selector, address(prenda)));
        prenda.setTreasury(address(prenda));
        vm.stopPrank();
    }

    function test_PauseAndUnpause() public {
        vm.startPrank(admin);
        prenda.pause();
        assertTrue(prenda.paused());
        vm.expectRevert(Pausable.EnforcedPause.selector);
        prenda.pause();

        prenda.unpause();
        assertFalse(prenda.paused());
        vm.expectRevert(Pausable.ExpectedPause.selector);
        prenda.unpause();
        vm.stopPrank();
    }

    function test_AdministrationChangesHandsInTwoSteps() public {
        address newAdmin = makeAddr("new admin");

        vm.prank(admin);
        prenda.transferOwnership(newAdmin);
        assertEq(prenda.owner(), admin);
        assertEq(prenda.pendingOwner(), newAdmin);

        // Until the new account accepts, it has no power and nobody can accept for it.
        vm.prank(newAdmin);
        vm.expectRevert(_unauthorized(newAdmin));
        prenda.pause();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        prenda.acceptOwnership();

        vm.prank(newAdmin);
        prenda.acceptOwnership();
        assertEq(prenda.owner(), newAdmin);
        assertEq(prenda.pendingOwner(), address(0));

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin));
        prenda.pause();
        vm.prank(newAdmin);
        prenda.pause();
    }

    function test_RevertWhen_RenouncingTheAdministration() public {
        vm.prank(admin);
        vm.expectRevert(Prenda.OwnershipCannotBeRenounced.selector);
        prenda.renounceOwnership();

        vm.prank(stranger);
        vm.expectRevert(Prenda.OwnershipCannotBeRenounced.selector);
        prenda.renounceOwnership();

        assertEq(prenda.owner(), admin);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Forgiving storage
    // ------------------------------------------------------------------------------------------------------------

    function test_ExtendFreeStorageForgivesWhatWasDue() public {
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 65 days);
        assertEq(prenda.storageFeeOf(TOKEN), 2 * uint256(FEE));
        uint48 newFreeUntil = uint48(block.timestamp);

        vm.expectEmit(address(prenda));
        emit Prenda.FreeStorageExtended(TOKEN, uint48(soldAt + FREE_PERIOD), newFreeUntil);
        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN, newFreeUntil);

        assertEq(prenda.storageFeeOf(TOKEN), 0);
        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, newFreeUntil);
        assertEq(feePerPeriod, FEE);
        assertEq(maxFee, MAX_FEE);

        // The count starts again from the new date.
        vm.warp(uint256(newFreeUntil) + 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
    }

    function test_ExtendFreeStorageToTheEndOfTimeMakesStorageFreeForGood() public {
        _sell(alice, TOKEN);

        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN, type(uint48).max);

        vm.warp(soldAt + 36500 days);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
    }

    function test_RevertWhen_FreeStorageWouldNotMoveForward() public {
        _sell(alice, TOKEN);
        uint48 current = uint48(soldAt + FREE_PERIOD);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.FreeStorageNotExtended.selector, TOKEN, current, current));
        prenda.extendFreeStorage(TOKEN, current);
        vm.expectRevert(abi.encodeWithSelector(Prenda.FreeStorageNotExtended.selector, TOKEN, current, current - 1));
        prenda.extendFreeStorage(TOKEN, current - 1);
        vm.expectRevert(abi.encodeWithSelector(Prenda.FreeStorageNotExtended.selector, TOKEN, current, uint48(0)));
        prenda.extendFreeStorage(TOKEN, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_ExtendingFreeStorageOfAnNftThatDoesNotExist() public {
        vm.prank(admin);
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.extendFreeStorage(TOKEN, type(uint48).max);

        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.claim(TOKEN, 0);

        vm.prank(admin);
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.extendFreeStorage(TOKEN, type(uint48).max);
    }

    /// @dev Two identical garments sold at the same time; only the second one gets an extension.
    function testFuzz_ExtendingFreeStorageNeverRaisesTheFee(uint48 extension, uint40 wait) public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        uint256 current = soldAt + FREE_PERIOD;
        uint48 newFreeUntil = uint48(bound(extension, current + 1, type(uint48).max));

        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN + 1, newFreeUntil);
        vm.warp(soldAt + wait);

        assertLe(prenda.storageFeeOf(TOKEN + 1), prenda.storageFeeOf(TOKEN));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Data of the NFT
    // ------------------------------------------------------------------------------------------------------------

    function test_TokenURIIsTheBaseAddressPlusTheTokenId() public {
        _sell(alice, TOKEN);
        _sell(alice, 2026);

        assertEq(prenda.tokenURI(TOKEN), "https://example.test/nft/1");
        assertEq(prenda.tokenURI(2026), "https://example.test/nft/2026");
    }

    function test_SetBaseURIChangesWhereTheDataIsServedButNotTheFingerprint() public {
        _sell(alice, TOKEN);

        vm.expectEmit(address(prenda));
        emit Prenda.BaseURIChanged("https://elsewhere.test/");
        vm.prank(admin);
        prenda.setBaseURI("https://elsewhere.test/");

        assertEq(prenda.tokenURI(TOKEN), "https://elsewhere.test/1");
        assertEq(prenda.contentHashOf(TOKEN), CONTENT_HASH);
    }

    function test_RevertWhen_AskingTheTokenURIOfAnNftThatDoesNotExist() public {
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.tokenURI(TOKEN);
    }
}
