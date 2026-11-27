// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Prenda} from "./Prenda.sol";
import {
    AcceptingReceiverMock,
    DoubleDipHolderMock,
    IMover,
    InertHolderMock,
    RejectingReceiverMock,
    WalletMock
} from "./mocks/HolderMocks.sol";
import {DirtyAnswerMock, FailingAnswerMock, LongAnswerMock} from "./mocks/ModuleAnswerMocks.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {OpenMinterMock} from "./mocks/OpenMinterMock.sol";
import {BlocklistTokenMock, CallbackTokenMock} from "./mocks/PaymentTokenMocks.sol";
import {RevertingToken} from "./mocks/RevertingToken.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

contract PrendaTest is Test {
    // A garment with 180 days of free storage, then 5 USDT0 for every 30 days, 30 USDT0 at most.
    uint32 internal constant FREE_PERIOD = 180 days;
    uint80 internal constant FEE = 5 * 10 ** 6;
    uint80 internal constant MAX_FEE = 30 * 10 ** 6;
    bytes32 internal constant CONTENT_HASH = keccak256("data of garment 1");
    uint256 internal constant TOKEN = 1;
    bytes32 internal constant ORDER = keccak256("order 1");
    string internal constant BASE_URI = "https://example.test/nft/";

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    OpenMinterMock internal minter;
    OpenMarketMock internal market;

    /// @dev Moment of the sale in every test: NFTs are created without moving the clock first.
    uint256 internal soldAt;

    function setUp() public {
        usdt = new TestUSDT0();
        (prenda, minter, market) = _deployWith(usdt);
        soldAt = block.timestamp;
    }

    /// @dev A full set: the NFT contract, a sale module allowed to mint and an authorized market.
    function _deployWith(
        IERC20 paymentToken
    ) internal returns (Prenda newPrenda, OpenMinterMock newMinter, OpenMarketMock newMarket) {
        newPrenda = new Prenda("Allka Archivo", "ALLKA", paymentToken, treasury, admin, BASE_URI);
        newMinter = new OpenMinterMock(newPrenda);
        newMarket = new OpenMarketMock(newPrenda);
        vm.startPrank(admin);
        newPrenda.setMinter(address(newMinter), true);
        newPrenda.authorizeMarket(address(newMarket));
        vm.stopPrank();
    }

    function _terms() internal pure returns (Prenda.StorageTerms memory) {
        return Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: MAX_FEE});
    }

    function _sell(address to, uint256 tokenId) internal {
        minter.mint(to, tokenId, _terms(), CONTENT_HASH);
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

    /// @dev The administration proposes the new treasury and the new treasury accepts.
    function _changeTreasury(Prenda target, address newTreasury) internal {
        vm.prank(admin);
        target.proposeTreasury(newTreasury);
        vm.prank(newTreasury);
        target.acceptTreasury();
    }

    function _authorizeAnotherMarket() internal returns (OpenMarketMock other) {
        other = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(other));
    }

    function _unauthorized(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account);
    }

    function _nonexistent(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId);
    }

    function _notApproved(address operator, uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, operator, tokenId);
    }

    function _transferNotAllowed(address executor) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, executor);
    }

    function _approvalNotAllowed(address operator) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Prenda.ApprovalNotAllowed.selector, operator);
    }

    function _invalidApprover(address approver) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, approver);
    }

    function _invalidReceiver(address receiver) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, receiver);
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
        assertEq(prenda.pendingTreasury(), address(0));
        assertEq(prenda.pauser(), address(0));
        assertEq(prenda.freeStorageForAllUntil(), 0);
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

    /// @dev The address a contract will get can be known beforehand: it must not be accepted as its own treasury.
    function test_RevertWhen_TreasuryIsTheNftContractItselfAtDeployment() public {
        address future = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        // It is rejected only if the contract really was being deployed at that address.
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidTreasury.selector, future));
        new Prenda("Allka Archivo", "ALLKA", usdt, future, admin, BASE_URI);
    }

    function test_RevertWhen_AdminIsZeroAtDeployment() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Prenda("Allka Archivo", "ALLKA", usdt, treasury, address(0), BASE_URI);
    }

    function test_SupportsTheErc721InterfacesAndNoOthers() public view {
        assertTrue(prenda.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(prenda.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(prenda.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertFalse(prenda.supportsInterface(0xffffffff));
        assertFalse(prenda.supportsInterface(0x780e9d63)); // ERC-721 Enumerable: not implemented
        assertFalse(prenda.supportsInterface(0x2a55205a)); // ERC-2981 royalties: not implemented
        assertFalse(prenda.supportsInterface(0x49064906)); // ERC-4906 metadata update: not implemented
    }

    // ------------------------------------------------------------------------------------------------------------
    // Creating an NFT (first sale)
    // ------------------------------------------------------------------------------------------------------------

    function test_MintCreatesTheNftWithItsStorageTermsAndFingerprint() public {
        vm.expectEmit(address(prenda));
        emit IERC721.Transfer(address(0), alice, TOKEN);
        vm.expectEmit(address(prenda));
        emit Prenda.Minted(
            TOKEN,
            alice,
            address(minter),
            uint48(soldAt + FREE_PERIOD),
            FEE,
            MAX_FEE,
            CONTENT_HASH
        );
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
        minter.mint(alice, TOKEN, Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}), CONTENT_HASH);

        vm.warp(soldAt + 3650 days);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
    }

    function test_MintAcceptsTheLongestFreePeriod() public {
        minter.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: type(uint32).max, feePerPeriod: FEE, maxFee: MAX_FEE}),
            CONTENT_HASH
        );

        (uint48 freeUntil, , ) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, soldAt + type(uint32).max);
    }

    function test_MintAcceptsACeilingOfExactlyOneInstalment() public {
        minter.mint(
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

    /// @dev The buyer gets no call in the middle of the sale, so a contract that cannot answer can still buy.
    function test_MintNeverCallsTheBuyer() public {
        InertHolderMock inert = new InertHolderMock();
        RejectingReceiverMock rejecting = new RejectingReceiverMock();

        _sell(address(inert), TOKEN);
        _sell(address(rejecting), TOKEN + 1);

        assertEq(prenda.ownerOf(TOKEN), address(inert));
        assertEq(prenda.ownerOf(TOKEN + 1), address(rejecting));
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

    function test_RevertWhen_MarketMints() public {
        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, address(market)));
        prenda.mint(alice, TOKEN, _terms(), CONTENT_HASH);
    }

    function test_RevertWhen_MinterWasRemoved() public {
        vm.prank(admin);
        prenda.setMinter(address(minter), false);

        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, address(minter)));
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
        prenda.claim(TOKEN, 0, ORDER);

        vm.expectRevert(abi.encodeWithSelector(Prenda.TokenIdAlreadyUsed.selector, TOKEN));
        _sell(bob, TOKEN);
    }

    function test_RevertWhen_AnotherMinterReusesATokenId() public {
        OpenMinterMock other = new OpenMinterMock(prenda);
        vm.prank(admin);
        prenda.setMinter(address(other), true);
        _sell(alice, TOKEN);

        vm.expectRevert(abi.encodeWithSelector(Prenda.TokenIdAlreadyUsed.selector, TOKEN));
        other.mint(bob, TOKEN, _terms(), CONTENT_HASH);
    }

    function test_RevertWhen_ContentHashIsEmpty() public {
        vm.expectRevert(Prenda.EmptyContentHash.selector);
        minter.mint(alice, TOKEN, _terms(), bytes32(0));
    }

    function test_RevertWhen_StorageHasNoFeeButHasACeiling() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidStorageTerms.selector, uint80(0), MAX_FEE));
        minter.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: 0, maxFee: MAX_FEE}),
            CONTENT_HASH
        );
    }

    function test_RevertWhen_StorageCeilingIsBelowOneInstalment() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidStorageTerms.selector, FEE, FEE - 1));
        minter.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: FEE - 1}),
            CONTENT_HASH
        );
    }

    function test_RevertWhen_StorageHasAFeeButNoCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidStorageTerms.selector, FEE, uint80(0)));
        minter.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: 0}),
            CONTENT_HASH
        );
    }

    function test_RevertWhen_MintToTheZeroAddress() public {
        vm.expectRevert(_invalidReceiver(address(0)));
        _sell(address(0), TOKEN);
    }

    /// @dev An NFT held by the NFT contract could never be claimed or moved.
    function test_RevertWhen_MintToTheNftContractItself() public {
        vm.expectRevert(_invalidReceiver(address(prenda)));
        _sell(address(prenda), TOKEN);

        assertFalse(prenda.isTokenIdUsed(TOKEN));
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
        minter.mint(
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
        prenda.claim(TOKEN, 0, ORDER);

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
        minter.mint(
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

    /// @dev One storage slot holds five fields. With every field at its limit, writing one leaves the others alone.
    function test_RecordFieldsAtTheirLimitsDoNotDisturbEachOther() public {
        minter.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({
                freePeriod: type(uint32).max,
                feePerPeriod: type(uint80).max,
                maxFee: type(uint80).max
            }),
            CONTENT_HASH
        );
        _approveMarket(alice);
        market.move(alice, bob, TOKEN);
        vm.prank(bob);
        prenda.approve(address(market), TOKEN);
        market.move(bob, bob, TOKEN);

        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, soldAt + type(uint32).max);
        assertEq(feePerPeriod, type(uint80).max);
        assertEq(maxFee, type(uint80).max);
        assertEq(prenda.transferCountOf(TOKEN), 2);
        assertTrue(prenda.isTokenIdUsed(TOKEN));

        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN, type(uint48).max - 60 days);
        (freeUntil, feePerPeriod, maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, type(uint48).max - 60 days);
        assertEq(feePerPeriod, type(uint80).max);
        assertEq(maxFee, type(uint80).max);
        assertEq(prenda.transferCountOf(TOKEN), 2);
        assertTrue(prenda.isTokenIdUsed(TOKEN));

        // The largest instalment, at the far end of the dates the contract can store.
        vm.warp(type(uint48).max - 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), type(uint80).max);
        vm.warp(type(uint48).max);
        assertEq(prenda.storageFeeOf(TOKEN), type(uint80).max);

        // After the burn the record is still there and the number stays used.
        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN, type(uint48).max);
        vm.prank(bob);
        prenda.claim(TOKEN, 0, ORDER);
        (freeUntil, feePerPeriod, maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, type(uint48).max);
        assertEq(feePerPeriod, type(uint80).max);
        assertEq(maxFee, type(uint80).max);
        assertEq(prenda.transferCountOf(TOKEN), 2);
        assertTrue(prenda.isTokenIdUsed(TOKEN));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Claiming the garment
    // ------------------------------------------------------------------------------------------------------------

    function test_FreeClaimBurnsTheNftAndMovesNoMoney() public {
        _sell(alice, TOKEN);

        vm.expectEmit(address(prenda));
        emit IERC721.Transfer(alice, address(0), TOKEN);
        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, alice, ORDER, 0);
        vm.prank(alice);
        prenda.claim(TOKEN, 0, ORDER);

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
        prenda.claim(TOKEN, type(uint256).max, ORDER);

        assertEq(prenda.balanceOf(alice), 0);
    }

    function test_FreeClaimNeverCallsThePaymentToken() public {
        (Prenda frozen, OpenMinterMock frozenMinter, ) = _deployWith(IERC20(address(new RevertingToken())));
        frozenMinter.mint(alice, TOKEN, _terms(), CONTENT_HASH);

        vm.prank(alice);
        frozen.claim(TOKEN, 0, ORDER);

        assertEq(frozen.balanceOf(alice), 0);
    }

    function test_RevertWhen_PaidClaimAndThePaymentTokenFails() public {
        (Prenda frozen, OpenMinterMock frozenMinter, ) = _deployWith(IERC20(address(new RevertingToken())));
        frozenMinter.mint(alice, TOKEN, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 30 days);

        vm.prank(alice);
        vm.expectRevert(RevertingToken.PaymentTokenWasCalled.selector);
        frozen.claim(TOKEN, FEE, ORDER);

        // Nothing happened: the NFT is still hers.
        assertEq(frozen.ownerOf(TOKEN), alice);
    }

    function test_FreeStorageExtensionUnblocksAClaimWhenThePaymentTokenFails() public {
        (Prenda frozen, OpenMinterMock frozenMinter, ) = _deployWith(IERC20(address(new RevertingToken())));
        frozenMinter.mint(alice, TOKEN, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 30 days);

        vm.prank(admin);
        frozen.extendFreeStorage(TOKEN, uint48(block.timestamp));

        vm.prank(alice);
        frozen.claim(TOKEN, 0, ORDER);
        assertEq(frozen.balanceOf(alice), 0);
    }

    function test_PaidClaimSendsTheFeeFromTheClaimerToTheTreasury() public {
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 65 days);
        uint256 fee = 2 * uint256(FEE);
        _fundAndApprove(alice, fee);

        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, alice, ORDER, fee);
        vm.prank(alice);
        prenda.claim(TOKEN, fee, ORDER);

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
        prenda.claim(TOKEN, 100 * 10 ** 6, ORDER);

        assertEq(usdt.balanceOf(alice), 100 * 10 ** 6 - FEE);
        assertEq(usdt.balanceOf(treasury), FEE);
        assertEq(usdt.balanceOf(address(prenda)), 0);
    }

    /// @dev The order server reads the fee from this event: it must be what was paid, not what was accepted.
    function test_ClaimedEventReportsTheFeePaidNotTheFeeAccepted() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        vm.prank(admin);
        prenda.extendFreeStorage(TOKEN + 1, type(uint48).max);
        _fundAndApprove(alice, 100 * 10 ** 6);

        vm.startPrank(alice);
        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, alice, ORDER, FEE);
        prenda.claim(TOKEN, 100 * 10 ** 6, ORDER);

        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN + 1, alice, ORDER, 0);
        prenda.claim(TOKEN + 1, type(uint256).max, ORDER);
        vm.stopPrank();
    }

    /// @dev The burn names its order: the reference travels in the event, and a claim with none is allowed.
    function test_ClaimPublishesTheOrderReference() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        bytes32 order = keccak256("order 77");

        vm.startPrank(alice);
        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, alice, order, 0);
        prenda.claim(TOKEN, 0, order);

        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN + 1, alice, bytes32(0), 0);
        prenda.claim(TOKEN + 1, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_PaidClaimGoesToTheTreasuryInForceAtThatMoment() public {
        address newTreasury = makeAddr("new treasury");
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        _fundAndApprove(alice, FEE);

        _changeTreasury(prenda, newTreasury);
        vm.prank(alice);
        prenda.claim(TOKEN, FEE, ORDER);

        assertEq(usdt.balanceOf(newTreasury), FEE);
        assertEq(usdt.balanceOf(treasury), 0);
    }

    /**
     * @dev The NFT is burned before the fee is collected. With the opposite order, a holder that gets a call from
     * the payment token could sell the NFT in the middle of its own claim and keep both the money and the garment.
     */
    function test_PaidClaimBurnsTheNftBeforeItCollectsTheFee() public {
        CallbackTokenMock token = new CallbackTokenMock();
        (Prenda other, OpenMinterMock otherMinter, OpenMarketMock otherMarket) = _deployWith(token);
        DoubleDipHolderMock cheater = new DoubleDipHolderMock(other, IMover(address(otherMarket)), stranger);
        otherMinter.mint(address(cheater), TOKEN, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        token.mint(address(cheater), FEE);
        cheater.prepare(TOKEN, token, FEE);

        cheater.claim(FEE);

        assertTrue(cheater.callbackRan());
        assertFalse(cheater.nftExistedDuringPayment());
        assertFalse(cheater.resaleDuringPaymentWorked());
        assertFalse(cheater.secondClaimDuringPaymentWorked());
        assertEq(other.balanceOf(stranger), 0);
        assertEq(other.balanceOf(address(cheater)), 0);
        assertEq(token.balanceOf(treasury), FEE);
        vm.expectRevert(_nonexistent(TOKEN));
        other.ownerOf(TOKEN);
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
        prenda.claim(TOKEN, 0, ORDER);
        vm.prank(bob);
        prenda.claim(TOKEN + 1, FEE, ORDER);

        assertEq(prenda.balanceOf(alice), 0);
        assertEq(prenda.balanceOf(bob), 0);
        assertEq(usdt.balanceOf(treasury), FEE);
    }

    function test_ClaimKeepsTheRecordOfTheGarment() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.claim(TOKEN, 0, ORDER);

        assertEq(prenda.contentHashOf(TOKEN), CONTENT_HASH);
        assertTrue(prenda.isTokenIdUsed(TOKEN));
    }

    function test_BuyerOnTheMarketCanClaimAndTheSellerCannot() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        market.move(alice, bob, TOKEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, alice));
        prenda.claim(TOKEN, 0, ORDER);

        vm.prank(bob);
        prenda.claim(TOKEN, 0, ORDER);
        assertEq(prenda.balanceOf(bob), 0);
    }

    function test_ContractWalletCanApproveAMarketAndClaimPaying() public {
        WalletMock wallet = new WalletMock(alice);
        _sell(address(wallet), TOKEN);
        _sell(address(wallet), TOKEN + 1);
        vm.warp(soldAt + FREE_PERIOD + 30 days);

        vm.startPrank(alice);
        usdt.mint(FEE);
        usdt.transfer(address(wallet), FEE);
        wallet.exec(address(usdt), abi.encodeCall(IERC20.approve, (address(prenda), FEE)));
        wallet.exec(address(prenda), abi.encodeCall(IERC721.setApprovalForAll, (address(market), true)));

        vm.expectEmit(address(prenda));
        emit Prenda.Claimed(TOKEN, address(wallet), ORDER, FEE);
        wallet.exec(address(prenda), abi.encodeCall(Prenda.claim, (TOKEN, FEE, ORDER)));
        vm.stopPrank();

        assertEq(usdt.balanceOf(treasury), FEE);
        market.move(address(wallet), bob, TOKEN + 1);
        assertEq(prenda.ownerOf(TOKEN + 1), bob);
    }

    function test_RevertWhen_ClaimerIsNotTheHolder() public {
        _sell(alice, TOKEN);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, stranger));
        prenda.claim(TOKEN, type(uint256).max, ORDER);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_AnApprovedMarketClaims() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);

        vm.prank(address(market));
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, address(market)));
        prenda.claim(TOKEN, type(uint256).max, ORDER);
    }

    /// @dev Once transfers are open an operator can move an NFT, but claiming stays with the holder.
    function test_RevertWhen_AnApprovedOperatorClaimsAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();
        vm.startPrank(alice);
        prenda.setApprovalForAll(bob, true);
        prenda.approve(bob, TOKEN);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, bob));
        prenda.claim(TOKEN, type(uint256).max, ORDER);
    }

    function test_RevertWhen_AdminOrMinterClaimsSomebodyElsesNft() public {
        _sell(alice, TOKEN);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, admin));
        prenda.claim(TOKEN, type(uint256).max, ORDER);

        vm.prank(address(minter));
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, address(minter)));
        prenda.claim(TOKEN, type(uint256).max, ORDER);
    }

    function test_RevertWhen_ClaimingAnNftThatDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.claim(TOKEN, type(uint256).max, ORDER);
    }

    function test_RevertWhen_ClaimingTwice() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.claim(TOKEN, 0, ORDER);

        vm.expectRevert(_nonexistent(TOKEN));
        prenda.claim(TOKEN, 0, ORDER);
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
        prenda.claim(TOKEN, FEE, ORDER);

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
        prenda.claim(TOKEN, FEE, ORDER);

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
        prenda.claim(TOKEN, FEE, ORDER);

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
        minter.mint(
            alice,
            TOKEN,
            Prenda.StorageTerms({freePeriod: freePeriod, feePerPeriod: feePerPeriod, maxFee: maxFee}),
            CONTENT_HASH
        );
        vm.warp(soldAt + wait);
        uint256 fee = prenda.storageFeeOf(TOKEN);
        _fundAndApprove(alice, maxFee);

        vm.prank(alice);
        prenda.claim(TOKEN, fee, ORDER);

        assertLe(fee, maxFee);
        assertEq(usdt.balanceOf(treasury), fee);
        assertEq(usdt.balanceOf(alice), maxFee - fee);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(prenda.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Claims when the issuer of the payment token blocks an account
    // (a model of what USDT0's issuer can do, not the real USDT0)
    // ------------------------------------------------------------------------------------------------------------

    function _blocklistSetup() internal returns (BlocklistTokenMock token, Prenda other) {
        token = new BlocklistTokenMock();
        OpenMinterMock otherMinter;
        (other, otherMinter, ) = _deployWith(token);
        otherMinter.mint(alice, TOKEN, _terms(), CONTENT_HASH);
        otherMinter.mint(alice, TOKEN + 1, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        token.mint(alice, 2 * uint256(FEE));
        vm.prank(alice);
        token.approve(address(other), 2 * uint256(FEE));
    }

    function test_PaidClaimReachesATreasuryThatTheIssuerBlocked() public {
        (BlocklistTokenMock token, Prenda other) = _blocklistSetup();
        token.setBlocked(treasury, true);

        vm.prank(alice);
        other.claim(TOKEN, FEE, ORDER);

        assertEq(token.balanceOf(treasury), FEE);
    }

    function test_RevertWhen_PaidClaimAndTheIssuerBlockedTheClaimer() public {
        (BlocklistTokenMock token, Prenda other) = _blocklistSetup();
        token.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, alice));
        other.claim(TOKEN, FEE, ORDER);

        // Her way out is a claim with no fee: the administration gives the garment more free storage.
        vm.prank(admin);
        other.extendFreeStorage(TOKEN, uint48(block.timestamp));
        vm.prank(alice);
        other.claim(TOKEN, 0, ORDER);
        assertEq(other.balanceOf(alice), 1);
    }

    /// @dev A known limit: if the issuer blocks the NFT contract, paid claims stop until storage is waived.
    function test_RevertWhen_PaidClaimAndTheIssuerBlockedTheNftContract() public {
        (BlocklistTokenMock token, Prenda other) = _blocklistSetup();
        token.setBlocked(address(other), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, address(other)));
        other.claim(TOKEN, FEE, ORDER);

        // Changing the treasury does not help: the blocked party is the one that moves the money.
        _changeTreasury(other, makeAddr("another treasury"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, address(other)));
        other.claim(TOKEN, FEE, ORDER);

        // The way out, one garment at a time: more free storage, then a claim that does not touch the token.
        vm.prank(admin);
        other.extendFreeStorage(TOKEN, uint48(block.timestamp));
        vm.prank(alice);
        other.claim(TOKEN, 0, ORDER);
        assertEq(other.balanceOf(alice), 1);
        assertEq(token.balanceOf(alice), 2 * uint256(FEE));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Transfers while they are closed
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_HolderTransfersDirectly() public {
        _sell(alice, TOKEN);

        vm.startPrank(alice);
        vm.expectRevert(_transferNotAllowed(alice));
        prenda.transferFrom(alice, bob, TOKEN);
        vm.expectRevert(_transferNotAllowed(alice));
        prenda.safeTransferFrom(alice, bob, TOKEN);
        vm.expectRevert(_transferNotAllowed(alice));
        prenda.safeTransferFrom(alice, bob, TOKEN, "");
        vm.stopPrank();

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_ApprovingSomeoneWhoIsNotAMarket() public {
        _sell(alice, TOKEN);

        vm.startPrank(alice);
        vm.expectRevert(_approvalNotAllowed(bob));
        prenda.approve(bob, TOKEN);
        vm.expectRevert(_approvalNotAllowed(bob));
        prenda.setApprovalForAll(bob, true);
        vm.stopPrank();
    }

    function test_RevertWhen_AMarketThatWasNeverAuthorizedMoves() public {
        OpenMarketMock rogue = new OpenMarketMock(prenda);
        _sell(alice, TOKEN);

        // The holder cannot even approve it...
        vm.prank(alice);
        vm.expectRevert(_approvalNotAllowed(address(rogue)));
        prenda.setApprovalForAll(address(rogue), true);

        // ...and it cannot move anything.
        vm.expectRevert(_transferNotAllowed(address(rogue)));
        rogue.move(alice, bob, TOKEN);
    }

    function test_AuthorizedMarketMovesAnNftItsHolderApproved() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        assertTrue(prenda.isApprovedForAll(alice, address(market)));

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
        assertEq(prenda.getApproved(TOKEN), address(market));

        market.move(alice, bob, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), bob);

        // The approval covered that NFT only.
        vm.expectRevert(_notApproved(address(market), TOKEN + 1));
        market.move(alice, bob, TOKEN + 1);
    }

    function test_RevertWhen_AuthorizedMarketMovesAnNftItsHolderDidNotApprove() public {
        _sell(alice, TOKEN);

        vm.expectRevert(_notApproved(address(market), TOKEN));
        market.move(alice, bob, TOKEN);
    }

    function test_RevertWhen_MarketMovesAfterTheHolderRevoked() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(market), true);
        prenda.setApprovalForAll(address(market), false);
        vm.stopPrank();

        vm.expectRevert(_notApproved(address(market), TOKEN));
        market.move(alice, bob, TOKEN);
    }

    /// @dev The central guarantee: authorizing a market gives it no power over NFTs that already exist.
    function test_RevertWhen_NewlyAuthorizedMarketMovesExistingNfts() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        OpenMarketMock newMarket = _authorizeAnotherMarket();

        assertFalse(prenda.isApprovedForAll(alice, address(newMarket)));
        vm.expectRevert(_notApproved(address(newMarket), TOKEN));
        newMarket.move(alice, bob, TOKEN);
        vm.expectRevert(_notApproved(address(newMarket), TOKEN));
        newMarket.move(alice, address(newMarket), TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev Only the holder approves. A market the holder trusted cannot extend that trust to another market.
    function test_RevertWhen_AnApprovedMarketPassesItsPermissionOn() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        OpenMarketMock newMarket = _authorizeAnotherMarket();

        vm.expectRevert(_invalidApprover(address(market)));
        market.grant(address(newMarket), TOKEN);

        assertEq(prenda.getApproved(TOKEN), address(0));
        vm.expectRevert(_notApproved(address(newMarket), TOKEN));
        newMarket.move(alice, bob, TOKEN);

        // The first market still does its own job with the approval alice gave it.
        market.move(alice, bob, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_SomeoneOtherThanTheHolderSetsOrClearsAnApproval() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        OpenMarketMock other = _authorizeAnotherMarket();
        vm.prank(alice);
        prenda.approve(address(other), TOKEN);

        // Not a market approved for all her NFTs...
        vm.expectRevert(_invalidApprover(address(market)));
        market.grant(address(0), TOKEN);
        // ...not the account that holds the approval for this NFT...
        vm.expectRevert(_invalidApprover(address(other)));
        other.grant(address(other), TOKEN);
        // ...not the administration, not a stranger.
        vm.prank(admin);
        vm.expectRevert(_invalidApprover(admin));
        prenda.approve(address(market), TOKEN);
        vm.prank(stranger);
        vm.expectRevert(_invalidApprover(stranger));
        prenda.approve(address(0), TOKEN);

        assertEq(prenda.getApproved(TOKEN), address(other));
    }

    function test_RevertWhen_ApprovingAnNftThatDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.approve(address(market), TOKEN);
    }

    function test_RevertWhen_MarketMovesFromTheWrongHolder() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, bob, TOKEN, alice));
        market.move(bob, stranger, TOKEN);
    }

    function test_RevertWhen_MarketMovesAnNftToTheNftContractItself() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.expectRevert(_invalidReceiver(address(prenda)));
        market.move(alice, address(prenda), TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_AdminMovesSomebodyElsesNft() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.prank(admin);
        vm.expectRevert(_transferNotAllowed(admin));
        prenda.transferFrom(alice, admin, TOKEN);
    }

    function test_RevertWhen_MarketApprovalForOneNftIsReusedAfterTheSale() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);
        market.move(alice, bob, TOKEN);

        // The approval alice gave ended with the transfer: the market cannot take the NFT from bob.
        assertEq(prenda.getApproved(TOKEN), address(0));
        vm.expectRevert(_notApproved(address(market), TOKEN));
        market.move(bob, alice, TOKEN);
    }

    function test_SafeMoveAsksTheReceiverAndAFailedMoveChangesNothing() public {
        AcceptingReceiverMock accepting = new AcceptingReceiverMock();
        RejectingReceiverMock rejecting = new RejectingReceiverMock();
        InertHolderMock inert = new InertHolderMock();
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.expectRevert(_invalidReceiver(address(rejecting)));
        market.safeMove(alice, address(rejecting), TOKEN);
        vm.expectRevert(_invalidReceiver(address(inert)));
        market.safeMove(alice, address(inert), TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.transferCountOf(TOKEN), 0);

        market.safeMove(alice, address(accepting), TOKEN);
        assertEq(prenda.ownerOf(TOKEN), address(accepting));
        assertEq(accepting.received(), 1);
        assertEq(prenda.transferCountOf(TOKEN), 1);
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

    /// @dev Every executed transfer counts, also one that leaves the NFT with the same holder.
    function test_TransferCountAlsoCountsAMoveToTheSameHolder() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);

        market.move(alice, alice, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.transferCountOf(TOKEN), 1);
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

    /// @dev Not the holder, not the administration, not a minter, not the treasury, not the receiver: nobody.
    function testFuzz_NobodyButAnAuthorizedMarketExecutesWhileClosed(address executor, address to) public {
        vm.assume(executor != address(market));
        vm.assume(to != address(0) && to != address(prenda));
        _sell(alice, TOKEN);
        _approveMarket(alice);

        vm.prank(executor);
        vm.expectRevert(_transferNotAllowed(executor));
        prenda.transferFrom(alice, to, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.transferCountOf(TOKEN), 0);
    }

    function testFuzz_NobodyButAnAuthorizedMarketCanBeApprovedWhileClosed(address operator) public {
        vm.assume(operator != address(market) && operator != address(0));
        _sell(alice, TOKEN);

        vm.startPrank(alice);
        vm.expectRevert(_approvalNotAllowed(operator));
        prenda.approve(operator, TOKEN);
        vm.expectRevert(_approvalNotAllowed(operator));
        prenda.setApprovalForAll(operator, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Disabled markets
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_DisabledMarketMoves() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        _approveMarket(alice);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN + 1);
        vm.prank(admin);
        prenda.disableMarket(address(market));

        vm.expectRevert(_transferNotAllowed(address(market)));
        market.move(alice, bob, TOKEN);
        vm.expectRevert(_transferNotAllowed(address(market)));
        market.move(alice, bob, TOKEN + 1);
    }

    function test_DisabledMarketLosesTheApprovalsItHad() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);
        assertTrue(prenda.isApprovedForAll(alice, address(market)));
        assertEq(prenda.getApproved(TOKEN), address(market));

        vm.prank(admin);
        prenda.disableMarket(address(market));
        assertFalse(prenda.isApprovedForAll(alice, address(market)));
        assertEq(prenda.getApproved(TOKEN), address(0));

        vm.prank(admin);
        prenda.openTransfers();
        assertFalse(prenda.isApprovedForAll(alice, address(market)));
        assertEq(prenda.getApproved(TOKEN), address(0));
    }

    /// @dev Once transfers are open any account a holder approved is reported, except a disabled market.
    function test_ApprovalOfAnNftIsReportedForAnyAccountAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN + 1);
        vm.startPrank(admin);
        prenda.openTransfers();
        prenda.disableMarket(address(market));
        vm.stopPrank();
        vm.prank(alice);
        prenda.approve(bob, TOKEN);

        assertEq(prenda.getApproved(TOKEN), bob);
        assertEq(prenda.getApproved(TOKEN + 1), address(0));
    }

    function test_RevertWhen_AskingTheApprovalOfAnNftThatDoesNotExist() public {
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.getApproved(TOKEN);

        _sell(alice, TOKEN);
        assertEq(prenda.getApproved(TOKEN), address(0));
        vm.prank(alice);
        prenda.claim(TOKEN, 0, ORDER);
        vm.expectRevert(_nonexistent(TOKEN));
        prenda.getApproved(TOKEN);
    }

    function test_RevertWhen_ApprovingADisabledMarket() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.disableMarket(address(market));

        vm.startPrank(alice);
        vm.expectRevert(_approvalNotAllowed(address(market)));
        prenda.setApprovalForAll(address(market), true);
        vm.expectRevert(_approvalNotAllowed(address(market)));
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
        vm.expectEmit(address(prenda));
        emit IERC721.ApprovalForAll(alice, address(market), false);
        prenda.setApprovalForAll(address(market), false);
        prenda.approve(address(0), TOKEN);
        vm.stopPrank();

        assertFalse(prenda.isApprovedForAll(alice, address(market)));
        assertEq(prenda.getApproved(TOKEN), address(0));
    }

    /// @dev A market that was switched off cannot use the approvals it had to bring another market in.
    function test_RevertWhen_DisabledMarketHandsAnApprovalToAnotherMarket() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        OpenMarketMock other = _authorizeAnotherMarket();
        vm.prank(admin);
        prenda.disableMarket(address(market));

        vm.expectRevert(_invalidApprover(address(market)));
        market.grant(address(other), TOKEN);
        vm.expectRevert(_notApproved(address(other), TOKEN));
        other.move(alice, stranger, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_DisabledMarketMovesAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        _approveMarket(alice);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN + 1);
        vm.startPrank(admin);
        prenda.disableMarket(address(market));
        prenda.openTransfers();
        vm.stopPrank();

        vm.expectRevert(_transferNotAllowed(address(market)));
        market.move(alice, bob, TOKEN);
        vm.expectRevert(_transferNotAllowed(address(market)));
        market.move(alice, bob, TOKEN + 1);

        vm.prank(alice);
        vm.expectRevert(_approvalNotAllowed(address(market)));
        prenda.approve(address(market), TOKEN);
    }

    function test_RevertWhen_MarketIsDisabledAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.startPrank(admin);
        prenda.openTransfers();
        prenda.disableMarket(address(market));
        vm.stopPrank();

        vm.expectRevert(_transferNotAllowed(address(market)));
        market.move(alice, bob, TOKEN);
    }

    /// @dev With transfers open anybody can be approved, so a disabled market must not be able to approve anybody.
    function test_RevertWhen_DisabledMarketHandsAnApprovalToSomeoneAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.startPrank(admin);
        prenda.disableMarket(address(market));
        prenda.openTransfers();
        vm.stopPrank();

        vm.expectRevert(_invalidApprover(address(market)));
        market.grant(stranger, TOKEN);
        vm.prank(stranger);
        vm.expectRevert(_notApproved(stranger, TOKEN));
        prenda.transferFrom(alice, stranger, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.getApproved(TOKEN), address(0));
    }

    function test_RevertWhen_MarketDisabledAfterOpeningHandsAnApprovalToSomeone() public {
        _sell(alice, TOKEN);
        _approveMarket(alice);
        vm.startPrank(admin);
        prenda.openTransfers();
        prenda.disableMarket(address(market));
        vm.stopPrank();

        vm.expectRevert(_invalidApprover(address(market)));
        market.grant(stranger, TOKEN);
        vm.prank(stranger);
        vm.expectRevert(_notApproved(stranger, TOKEN));
        prenda.safeTransferFrom(alice, stranger, TOKEN);

        assertEq(prenda.ownerOf(TOKEN), alice);
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
        assertTrue(prenda.isApprovedForAll(alice, stranger));
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

    /// @dev Also with transfers open, only the holder approves: an operator moves NFTs but cannot bring others in.
    function test_RevertWhen_AnOperatorGivesAnApprovalAfterOpening() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();
        vm.prank(alice);
        prenda.setApprovalForAll(bob, true);

        vm.prank(bob);
        vm.expectRevert(_invalidApprover(bob));
        prenda.approve(stranger, TOKEN);

        vm.prank(bob);
        prenda.transferFrom(alice, bob, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_SomeoneWithoutApprovalMovesAfterOpening() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();

        vm.prank(stranger);
        vm.expectRevert(_notApproved(stranger, TOKEN));
        prenda.transferFrom(alice, stranger, TOKEN);

        vm.prank(admin);
        vm.expectRevert(_notApproved(admin, TOKEN));
        prenda.transferFrom(alice, admin, TOKEN);
    }

    function test_RevertWhen_HolderSendsAnNftToTheNftContractItselfAfterOpening() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();

        vm.startPrank(alice);
        vm.expectRevert(_invalidReceiver(address(prenda)));
        prenda.transferFrom(alice, address(prenda), TOKEN);
        vm.expectRevert(_invalidReceiver(address(prenda)));
        prenda.safeTransferFrom(alice, address(prenda), TOKEN);
        vm.stopPrank();

        assertEq(prenda.ownerOf(TOKEN), alice);
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
    // Approvals taken back (markets use the count to drop the offers made under an approval)
    // ------------------------------------------------------------------------------------------------------------

    function test_TakingBackAnApprovalForAllIsCounted() public {
        assertEq(prenda.approvalsRevoked(alice, address(market)), 0);
        _approveMarket(alice);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 0);

        vm.prank(alice);
        prenda.setApprovalForAll(address(market), false);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 1);

        // Taking back what is no longer given is not counted.
        vm.prank(alice);
        prenda.setApprovalForAll(address(market), false);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 1);

        // Giving it again, even twice, is not counted. Taking it back again is.
        _approveMarket(alice);
        _approveMarket(alice);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 1);
        vm.prank(alice);
        prenda.setApprovalForAll(address(market), false);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 2);
    }

    function test_ClearingOrReplacingTheApprovalOfAnNftIsCounted() public {
        _sell(alice, TOKEN);
        OpenMarketMock other = _authorizeAnotherMarket();
        vm.startPrank(alice);
        prenda.approve(address(market), TOKEN);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 0);
        // Approving the same account again takes nothing back.
        prenda.approve(address(market), TOKEN);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 0);

        // Replacing it: the first market lost the approval, the second did not.
        prenda.approve(address(other), TOKEN);
        assertEq(prenda.approvalsRevoked(alice, address(market)), 1);
        assertEq(prenda.approvalsRevoked(alice, address(other)), 0);

        // Clearing it.
        prenda.approve(address(0), TOKEN);
        assertEq(prenda.approvalsRevoked(alice, address(other)), 1);

        // Clearing when there is none takes nothing back from anybody.
        prenda.approve(address(0), TOKEN);
        vm.stopPrank();
        assertEq(prenda.approvalsRevoked(alice, address(market)), 1);
        assertEq(prenda.approvalsRevoked(alice, address(other)), 1);
        assertEq(prenda.approvalsRevoked(alice, address(0)), 0);
    }

    /// @dev Each holder has a count of its own for each operator.
    function test_ApprovalsTakenBackAreCountedForEachHolderAndOperator() public {
        OpenMarketMock other = _authorizeAnotherMarket();
        _approveMarket(alice);
        _approveMarket(bob);
        vm.prank(alice);
        prenda.setApprovalForAll(address(other), true);

        vm.prank(alice);
        prenda.setApprovalForAll(address(market), false);

        assertEq(prenda.approvalsRevoked(alice, address(market)), 1);
        assertEq(prenda.approvalsRevoked(bob, address(market)), 0);
        assertEq(prenda.approvalsRevoked(alice, address(other)), 0);
        assertEq(prenda.approvalsRevoked(address(market), alice), 0);
    }

    /// @dev An approval that goes away because the NFT itself left its holder is not an approval taken back.
    function test_ApprovalsClearedByATransferOrAClaimAreNotCounted() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(market), TOKEN);
        prenda.approve(address(market), TOKEN + 1);
        vm.stopPrank();

        market.move(alice, bob, TOKEN);
        vm.prank(alice);
        prenda.claim(TOKEN + 1, 0, ORDER);

        assertEq(prenda.approvalsRevoked(alice, address(market)), 0);
        assertEq(prenda.approvalsRevoked(bob, address(market)), 0);
    }

    /// @dev Taking an approval back from a market that was disabled is always possible, and it is counted.
    function test_TakingAnApprovalBackFromADisabledMarketIsCounted() public {
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

        assertEq(prenda.approvalsRevoked(alice, address(market)), 2);
    }

    /// @dev Somebody who is not the holder cannot make the count of the holder move.
    function test_RevertWhen_SomeoneElseTriesToTakeAnApprovalBackForTheHolder() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.approve(address(market), TOKEN);

        vm.prank(stranger);
        vm.expectRevert(_invalidApprover(stranger));
        prenda.approve(address(0), TOKEN);
        vm.expectRevert(_invalidApprover(address(market)));
        market.grant(address(0), TOKEN);

        assertEq(prenda.approvalsRevoked(alice, address(market)), 0);
        assertEq(prenda.approvalsRevoked(stranger, address(market)), 0);
        assertEq(prenda.getApproved(TOKEN), address(market));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_SomeoneElseUsesTheAdministrationSwitches() public {
        _sell(alice, TOKEN);
        OpenMarketMock other = new OpenMarketMock(prenda);
        address[4] memory callers = [stranger, alice, address(minter), address(market)];

        for (uint256 i = 0; i < callers.length; i++) {
            address caller = callers[i];
            bytes memory expected = _unauthorized(caller);
            vm.startPrank(caller);

            vm.expectRevert(expected);
            prenda.setMinter(address(other), true);
            vm.expectRevert(expected);
            prenda.setMinter(address(minter), false);
            vm.expectRevert(expected);
            prenda.authorizeMarket(address(other));
            vm.expectRevert(expected);
            prenda.disableMarket(address(market));
            vm.expectRevert(expected);
            prenda.openTransfers();
            vm.expectRevert(expected);
            prenda.proposeTreasury(caller);
            vm.expectRevert(expected);
            prenda.setPauser(caller);
            vm.expectRevert(expected);
            prenda.extendFreeStorageForAll(type(uint48).max);
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
        OpenMinterMock other = new OpenMinterMock(prenda);

        vm.startPrank(admin);
        vm.expectEmit(address(prenda));
        emit Prenda.MinterSet(address(other), true);
        prenda.setMinter(address(other), true);
        assertTrue(prenda.isMinter(address(other)));

        vm.expectEmit(address(prenda));
        emit Prenda.MinterSet(address(other), false);
        prenda.setMinter(address(other), false);
        assertFalse(prenda.isMinter(address(other)));
        vm.stopPrank();
    }

    /// @dev Accounts that are not a module built for this NFT contract, each for a different reason.
    function _notModules() internal returns (address[9] memory) {
        (Prenda otherPrenda, OpenMinterMock otherMinter, ) = _deployWith(usdt);
        return [
            stranger, // an ordinary wallet
            address(usdt), // a contract that knows nothing about this project
            address(new RevertingToken()), // a contract that fails on every call
            address(otherMinter), // a module built for another NFT contract
            address(otherPrenda), // another NFT contract
            address(2), // an account that answers 32 bytes that are not this contract
            address(new FailingAnswerMock(address(prenda))), // names this contract, but by failing
            address(new LongAnswerMock(address(prenda))), // names this contract, followed by something else
            address(new DirtyAnswerMock(address(prenda))) // names this contract, with a bit set above the address
        ];
    }

    function test_RevertWhen_MinterIsNotAModuleOfThisContract() public {
        address[9] memory wrong = _notModules();

        vm.startPrank(admin);
        for (uint256 i = 0; i < wrong.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(Prenda.NotAModule.selector, wrong[i]));
            prenda.setMinter(wrong[i], true);
        }
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotAModule.selector, address(prenda)));
        prenda.setMinter(address(prenda), true);
        vm.stopPrank();
    }

    function test_RevertWhen_MarketIsNotAModuleOfThisContract() public {
        address[9] memory wrong = _notModules();

        vm.startPrank(admin);
        for (uint256 i = 0; i < wrong.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(Prenda.NotAModule.selector, wrong[i]));
            prenda.authorizeMarket(wrong[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotAModule.selector, address(prenda)));
        prenda.authorizeMarket(address(prenda));
        vm.stopPrank();
    }

    /// @dev A known limit: the answer of a module does not say whether it is a sale module or a market, so each can
    /// be registered as the other. Disabling a sale module "as a market" does not stop it from creating NFTs: that
    /// is done by removing it as a minter.
    function test_ModuleCheckDoesNotTellASaleModuleFromAMarket() public {
        vm.startPrank(admin);
        prenda.authorizeMarket(address(minter));
        prenda.setMinter(address(market), true);
        prenda.disableMarket(address(minter));
        vm.stopPrank();

        assertTrue(prenda.isMinter(address(minter)));
        _sell(alice, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev Stopping a module must always be possible, whatever that account answers by then.
    function test_RemovingAMinterAsksNothingFromIt() public {
        vm.etch(address(minter), "");
        assertEq(address(minter).code.length, 0);

        vm.prank(admin);
        prenda.setMinter(address(minter), false);

        assertFalse(prenda.isMinter(address(minter)));
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
        OpenMarketMock neverAuthorized = new OpenMarketMock(prenda);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.MarketNotAuthorized.selector, stranger));
        prenda.disableMarket(stranger);
        vm.expectRevert(abi.encodeWithSelector(Prenda.MarketNotAuthorized.selector, address(neverAuthorized)));
        prenda.disableMarket(address(neverAuthorized));

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

    function test_TreasuryChangesOnlyWhenTheNewOneAccepts() public {
        address newTreasury = makeAddr("new treasury");

        vm.expectEmit(address(prenda));
        emit Prenda.TreasuryProposed(newTreasury);
        vm.prank(admin);
        prenda.proposeTreasury(newTreasury);

        // Proposing changes nothing yet.
        assertEq(prenda.treasury(), treasury);
        assertEq(prenda.pendingTreasury(), newTreasury);

        vm.expectEmit(address(prenda));
        emit Prenda.TreasuryChanged(treasury, newTreasury);
        vm.prank(newTreasury);
        prenda.acceptTreasury();

        assertEq(prenda.treasury(), newTreasury);
        assertEq(prenda.pendingTreasury(), address(0));

        // Accepting works once.
        vm.prank(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotPendingTreasury.selector, newTreasury));
        prenda.acceptTreasury();
    }

    function test_MoneyKeepsGoingToTheOldTreasuryUntilTheNewOneAccepts() public {
        address newTreasury = makeAddr("new treasury");
        _sell(alice, TOKEN);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        _fundAndApprove(alice, FEE);
        vm.prank(admin);
        prenda.proposeTreasury(newTreasury);

        vm.prank(alice);
        prenda.claim(TOKEN, FEE, ORDER);

        assertEq(usdt.balanceOf(treasury), FEE);
        assertEq(usdt.balanceOf(newTreasury), 0);
    }

    /// @dev A mistyped address never becomes the treasury: nobody can accept for it.
    function test_RevertWhen_SomeoneElseAcceptsTheTreasury() public {
        address newTreasury = makeAddr("new treasury");
        vm.prank(admin);
        prenda.proposeTreasury(newTreasury);
        address[3] memory callers = [stranger, admin, treasury];

        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Prenda.NotPendingTreasury.selector, callers[i]));
            prenda.acceptTreasury();
        }

        assertEq(prenda.treasury(), treasury);
        assertEq(prenda.pendingTreasury(), newTreasury);
    }

    function test_RevertWhen_AcceptingTheTreasuryWithNoProposal() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotPendingTreasury.selector, stranger));
        prenda.acceptTreasury();
    }

    function test_TreasuryProposalCanBeReplacedAndWithdrawn() public {
        address first = makeAddr("first candidate");
        address second = makeAddr("second candidate");
        vm.startPrank(admin);
        prenda.proposeTreasury(first);
        prenda.proposeTreasury(second);
        vm.stopPrank();

        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotPendingTreasury.selector, first));
        prenda.acceptTreasury();

        // Proposing the zero address withdraws the proposal.
        vm.expectEmit(address(prenda));
        emit Prenda.TreasuryProposed(address(0));
        vm.prank(admin);
        prenda.proposeTreasury(address(0));
        vm.prank(second);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotPendingTreasury.selector, second));
        prenda.acceptTreasury();

        assertEq(prenda.treasury(), treasury);
        assertEq(prenda.pendingTreasury(), address(0));
    }

    function test_RevertWhen_ProposingTheContractItselfAsTreasury() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.InvalidTreasury.selector, address(prenda)));
        prenda.proposeTreasury(address(prenda));

        assertEq(prenda.pendingTreasury(), address(0));
    }

    // ------------------------------------------------------------------------------------------------------------
    // The account that can only pause
    // ------------------------------------------------------------------------------------------------------------

    function test_PauserCanPauseButNotResume() public {
        address pauser = makeAddr("pauser");

        vm.expectEmit(address(prenda));
        emit Prenda.PauserChanged(address(0), pauser);
        vm.prank(admin);
        prenda.setPauser(pauser);
        assertEq(prenda.pauser(), pauser);

        vm.prank(pauser);
        prenda.pause();
        assertTrue(prenda.paused());

        vm.prank(pauser);
        vm.expectRevert(_unauthorized(pauser));
        prenda.unpause();

        vm.prank(admin);
        prenda.unpause();
        assertFalse(prenda.paused());
    }

    function test_RevertWhen_PauserUsesAnyOtherSwitch() public {
        address pauser = makeAddr("pauser");
        _sell(alice, TOKEN);
        OpenMarketMock other = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.setPauser(pauser);
        bytes memory expected = _unauthorized(pauser);

        vm.startPrank(pauser);
        vm.expectRevert(expected);
        prenda.setMinter(address(minter), false);
        vm.expectRevert(expected);
        prenda.authorizeMarket(address(other));
        vm.expectRevert(expected);
        prenda.disableMarket(address(market));
        vm.expectRevert(expected);
        prenda.openTransfers();
        vm.expectRevert(expected);
        prenda.proposeTreasury(pauser);
        vm.expectRevert(expected);
        prenda.setPauser(stranger);
        vm.expectRevert(expected);
        prenda.extendFreeStorage(TOKEN, type(uint48).max);
        vm.expectRevert(expected);
        prenda.extendFreeStorageForAll(type(uint48).max);
        vm.expectRevert(expected);
        prenda.setBaseURI("https://elsewhere.test/");
        vm.expectRevert(expected);
        prenda.transferOwnership(pauser);
        vm.stopPrank();
    }

    function test_RevertWhen_AFormerPauserPauses() public {
        address pauser = makeAddr("pauser");
        address nextPauser = makeAddr("next pauser");
        vm.startPrank(admin);
        prenda.setPauser(pauser);
        vm.expectEmit(address(prenda));
        emit Prenda.PauserChanged(pauser, nextPauser);
        prenda.setPauser(nextPauser);
        vm.stopPrank();

        vm.prank(pauser);
        vm.expectRevert(_unauthorized(pauser));
        prenda.pause();
        vm.prank(nextPauser);
        prenda.pause();
        assertTrue(prenda.paused());

        // And the administration can leave nobody in that role.
        vm.prank(admin);
        prenda.setPauser(address(0));
        assertEq(prenda.pauser(), address(0));
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

    /// @dev The pause is for sales and transfers. Approvals, claims and every administration switch keep working.
    function test_PauseStopsNothingButMintsAndTransfers() public {
        _sell(alice, TOKEN);
        OpenMarketMock otherMarket = new OpenMarketMock(prenda);
        OpenMinterMock otherMinter = new OpenMinterMock(prenda);
        address newAdmin = makeAddr("new admin");
        address anotherTreasury = makeAddr("another treasury");
        vm.prank(admin);
        prenda.pause();

        // Holders: approvals and revocations.
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(market), true);
        prenda.approve(address(market), TOKEN);
        prenda.approve(address(0), TOKEN);
        prenda.setApprovalForAll(address(market), false);
        vm.stopPrank();

        // Administration: every switch.
        vm.startPrank(admin);
        prenda.extendFreeStorage(TOKEN, uint48(soldAt + FREE_PERIOD + 1));
        prenda.extendFreeStorageForAll(uint48(soldAt + 1));
        prenda.proposeTreasury(anotherTreasury);
        prenda.setPauser(makeAddr("pauser"));
        prenda.setMinter(address(otherMinter), true);
        prenda.setMinter(address(otherMinter), false);
        prenda.authorizeMarket(address(otherMarket));
        prenda.disableMarket(address(otherMarket));
        prenda.setBaseURI("https://elsewhere.test/");
        prenda.openTransfers();
        prenda.transferOwnership(newAdmin);
        vm.stopPrank();
        vm.prank(newAdmin);
        prenda.acceptOwnership();
        vm.prank(anotherTreasury);
        prenda.acceptTreasury();
        assertEq(prenda.treasury(), anotherTreasury);

        // Views.
        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
        assertEq(prenda.tokenURI(TOKEN), "https://elsewhere.test/1");

        // Transfers are still stopped, by any route.
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        prenda.safeTransferFrom(alice, bob, TOKEN);
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

    function test_AdministrationHandoverCanBeRedirectedAndCancelled() public {
        address first = makeAddr("first candidate");
        address second = makeAddr("second candidate");

        vm.startPrank(admin);
        prenda.transferOwnership(first);
        prenda.transferOwnership(second);
        vm.stopPrank();

        vm.prank(first);
        vm.expectRevert(_unauthorized(first));
        prenda.acceptOwnership();

        // Cancelling: nobody is pending and nobody can accept. The administration never becomes the zero address.
        vm.prank(admin);
        prenda.transferOwnership(address(0));
        assertEq(prenda.pendingOwner(), address(0));
        vm.prank(second);
        vm.expectRevert(_unauthorized(second));
        prenda.acceptOwnership();
        assertEq(prenda.owner(), admin);
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
        prenda.claim(TOKEN, 0, ORDER);

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
    // Forgiving storage for every garment at once
    // ------------------------------------------------------------------------------------------------------------

    function test_ExtendFreeStorageForAllForgivesEveryGarment() public {
        _sell(alice, TOKEN);
        _sell(bob, TOKEN + 1);
        vm.warp(soldAt + FREE_PERIOD + 65 days);
        assertEq(prenda.storageFeeOf(TOKEN), 2 * uint256(FEE));
        assertEq(prenda.storageFeeOf(TOKEN + 1), 2 * uint256(FEE));
        uint48 newFreeUntil = uint48(block.timestamp);

        vm.expectEmit(address(prenda));
        emit Prenda.FreeStorageForAllExtended(0, newFreeUntil);
        vm.prank(admin);
        prenda.extendFreeStorageForAll(newFreeUntil);

        assertEq(prenda.freeStorageForAllUntil(), newFreeUntil);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
        assertEq(prenda.storageFeeOf(TOKEN + 1), 0);
        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, newFreeUntil);
        assertEq(feePerPeriod, FEE);
        assertEq(maxFee, MAX_FEE);

        // The count starts again from the new date, for every garment.
        vm.warp(uint256(newFreeUntil) + 30 days - 1);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
        vm.warp(uint256(newFreeUntil) + 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
        assertEq(prenda.storageFeeOf(TOKEN + 1), FEE);
    }

    function test_FreeStorageForAllAlsoCoversGarmentsSoldLater() public {
        uint48 forAll = uint48(soldAt + 1000 days);
        vm.prank(admin);
        prenda.extendFreeStorageForAll(forAll);

        // Sold ten days later: its own free period would end long before the date given to all.
        vm.warp(soldAt + 10 days);
        _sell(alice, TOKEN);

        (uint48 freeUntil, , ) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, forAll);
        vm.warp(uint256(forAll) + 30 days - 1);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
        vm.warp(uint256(forAll) + 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
    }

    function test_AGarmentKeepsItsOwnDateWhenThatOneIsLater() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.extendFreeStorageForAll(uint48(soldAt + 10 days));

        (uint48 freeUntil, , ) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, soldAt + FREE_PERIOD);
        vm.warp(soldAt + FREE_PERIOD + 30 days - 1);
        assertEq(prenda.storageFeeOf(TOKEN), 0);
        vm.warp(soldAt + FREE_PERIOD + 30 days);
        assertEq(prenda.storageFeeOf(TOKEN), FEE);
    }

    function test_UnusedTokenIdHasNoStorageTermsEvenWithFreeStorageForAll() public {
        vm.prank(admin);
        prenda.extendFreeStorageForAll(type(uint48).max);

        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, 0);
        assertEq(feePerPeriod, 0);
        assertEq(maxFee, 0);
    }

    function test_RevertWhen_FreeStorageForAllWouldNotMoveForward() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Prenda.FreeStorageForAllNotExtended.selector, uint48(0), uint48(0)));
        prenda.extendFreeStorageForAll(0);

        prenda.extendFreeStorageForAll(1000);
        vm.expectRevert(
            abi.encodeWithSelector(Prenda.FreeStorageForAllNotExtended.selector, uint48(1000), uint48(1000))
        );
        prenda.extendFreeStorageForAll(1000);
        vm.expectRevert(
            abi.encodeWithSelector(Prenda.FreeStorageForAllNotExtended.selector, uint48(1000), uint48(999))
        );
        prenda.extendFreeStorageForAll(999);

        prenda.extendFreeStorageForAll(1001);
        vm.stopPrank();
        assertEq(prenda.freeStorageForAllUntil(), 1001);
    }

    /// @dev Giving one garment more free storage has to improve on what it already has, from either date.
    function test_RevertWhen_AGarmentIsExtendedToADateNotLaterThanTheOneGivenToAll() public {
        _sell(alice, TOKEN);
        uint48 forAll = uint48(soldAt + FREE_PERIOD + 100 days);

        vm.startPrank(admin);
        prenda.extendFreeStorageForAll(forAll);
        vm.expectRevert(abi.encodeWithSelector(Prenda.FreeStorageNotExtended.selector, TOKEN, forAll, forAll));
        prenda.extendFreeStorage(TOKEN, forAll);
        vm.expectRevert(abi.encodeWithSelector(Prenda.FreeStorageNotExtended.selector, TOKEN, forAll, forAll - 1));
        prenda.extendFreeStorage(TOKEN, forAll - 1);

        vm.expectEmit(address(prenda));
        emit Prenda.FreeStorageExtended(TOKEN, forAll, forAll + 1);
        prenda.extendFreeStorage(TOKEN, forAll + 1);
        vm.stopPrank();

        (uint48 freeUntil, , ) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, forAll + 1);
    }

    /// @dev The reason this exists: one operation for all the garments if the payment token stops working.
    function test_FreeStorageForAllUnblocksEveryClaimWhenThePaymentTokenFails() public {
        (Prenda frozen, OpenMinterMock frozenMinter, ) = _deployWith(IERC20(address(new RevertingToken())));
        frozenMinter.mint(alice, TOKEN, _terms(), CONTENT_HASH);
        frozenMinter.mint(bob, TOKEN + 1, _terms(), CONTENT_HASH);
        vm.warp(soldAt + FREE_PERIOD + 65 days);
        vm.prank(alice);
        vm.expectRevert(RevertingToken.PaymentTokenWasCalled.selector);
        frozen.claim(TOKEN, type(uint256).max, ORDER);

        vm.prank(admin);
        frozen.extendFreeStorageForAll(uint48(block.timestamp));

        vm.prank(alice);
        frozen.claim(TOKEN, 0, ORDER);
        vm.prank(bob);
        frozen.claim(TOKEN + 1, 0, ORDER);
        assertEq(frozen.balanceOf(alice), 0);
        assertEq(frozen.balanceOf(bob), 0);
    }

    /// @dev Two identical NFT contracts with the same garment; only the second one gets free storage for all.
    function testFuzz_ExtendingFreeStorageForAllNeverRaisesAFee(uint48 forAll, uint40 wait, uint32 freePeriod) public {
        (Prenda twin, OpenMinterMock twinMinter, ) = _deployWith(usdt);
        Prenda.StorageTerms memory terms = Prenda.StorageTerms({
            freePeriod: freePeriod,
            feePerPeriod: FEE,
            maxFee: MAX_FEE
        });
        minter.mint(alice, TOKEN, terms, CONTENT_HASH);
        twinMinter.mint(alice, TOKEN, terms, CONTENT_HASH);
        forAll = uint48(bound(forAll, 1, type(uint48).max));

        vm.prank(admin);
        twin.extendFreeStorageForAll(forAll);
        vm.warp(soldAt + wait);

        assertLe(twin.storageFeeOf(TOKEN), prenda.storageFeeOf(TOKEN));
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
