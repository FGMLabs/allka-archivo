// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Mercado} from "./Mercado.sol";
import {Prenda} from "./Prenda.sol";
import {ReentrantMarketBuyerMock} from "./mocks/BuyerMocks.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {OpenMinterMock} from "./mocks/OpenMinterMock.sol";
import {BlocklistTokenMock, CallbackTokenMock, FalseReturningTokenMock} from "./mocks/PaymentTokenMocks.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

contract MercadoTest is Test {
    uint80 internal constant MIN_PRICE = 10 * 10 ** 6;
    /// @dev The longest an offer can last. The contract has it as a constant.
    uint48 internal constant MAX_DURATION = 30 days;
    uint80 internal constant PRICE = 100 * 10 ** 6;
    uint256 internal constant FEE = 2 * 10 ** 6;
    uint256 internal constant TOKEN = 1;
    bytes32 internal constant ORDER = keccak256("order 1");

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    OpenMinterMock internal minter;
    Mercado internal mercado;

    uint256 internal start;

    function setUp() public {
        usdt = new TestUSDT0();
        (prenda, minter, mercado) = _deployWith(usdt);
        start = block.timestamp;
    }

    function _deployWith(
        IERC20 paymentToken
    ) internal returns (Prenda newPrenda, OpenMinterMock newMinter, Mercado newMercado) {
        newPrenda = new Prenda("Allka Archivo", "ALLKA", paymentToken, treasury, admin, "https://example.test/nft/");
        newMinter = new OpenMinterMock(newPrenda);
        newMercado = new Mercado(newPrenda, MIN_PRICE);
        vm.startPrank(admin);
        newPrenda.setMinter(address(newMinter), true);
        newPrenda.authorizeMarket(address(newMercado));
        vm.stopPrank();
    }

    /// @dev Stands for the first sale: `to` becomes the holder of the NFT, with no storage fee.
    function _sell(address to, uint256 tokenId) internal {
        minter.mint(
            to,
            tokenId,
            Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}),
            keccak256(abi.encode(tokenId))
        );
    }

    function _approveMercado(address holder) internal {
        vm.prank(holder);
        prenda.setApprovalForAll(address(mercado), true);
    }

    /// @dev `seller` gets the NFT, approves the market and offers it at `price` for as long as allowed.
    function _sellAndList(address seller, uint256 tokenId, uint80 price) internal {
        _sell(seller, tokenId);
        _approveMercado(seller);
        vm.prank(seller);
        mercado.list(tokenId, price, uint48(block.timestamp + MAX_DURATION));
    }

    /// @dev Gives `account` exactly `amount` test USDT0 and approves the market for exactly that amount.
    function _fundAndApprove(address account, uint256 amount) internal {
        vm.startPrank(account);
        usdt.mint(amount);
        usdt.approve(address(mercado), amount);
        vm.stopPrank();
    }

    function _nonexistent(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId);
    }

    function _assertNoListing(uint256 tokenId) internal view {
        Mercado.Listing memory listing = mercado.listingOf(tokenId);
        assertEq(listing.seller, address(0));
        assertEq(listing.price, 0);
        assertEq(listing.expiresAt, 0);
        assertEq(listing.transferCount, 0);
        assertEq(listing.approvalsForAllRevoked, 0);
        assertEq(listing.tokenApprovalsRevoked, 0);
    }

    /// @dev A second authorized market through which NFTs can change hands behind the back of the first.
    function _anotherMarket() internal returns (OpenMarketMock otherMarket) {
        otherMarket = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(otherMarket));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function test_DeploymentRecordsTheSetup() public view {
        assertEq(address(mercado.prenda()), address(prenda));
        assertEq(address(mercado.paymentToken()), address(usdt));
        assertEq(mercado.minPrice(), MIN_PRICE);
        assertEq(mercado.MAX_LISTING_DURATION(), 30 days);
        assertEq(mercado.FEE_BPS(), 200);
        assertEq(uint8(prenda.marketStatus(address(mercado))), uint8(Prenda.MarketStatus.Authorized));
    }

    function test_RevertWhen_MinimumPriceWouldLetTheFeeRoundToZero() public {
        vm.expectRevert(abi.encodeWithSelector(Mercado.MinimumPriceTooLow.selector, uint80(49)));
        new Mercado(prenda, 49);
        vm.expectRevert(abi.encodeWithSelector(Mercado.MinimumPriceTooLow.selector, uint80(0)));
        new Mercado(prenda, 0);

        // With 50 units the fee is exactly one unit.
        Mercado smallest = new Mercado(prenda, 50);
        assertEq(smallest.minPrice(), 50);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Offering an NFT
    // ------------------------------------------------------------------------------------------------------------

    function test_ListRecordsTheOffer() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);
        uint48 expiresAt = uint48(start + 7 days);

        vm.expectEmit(address(mercado));
        emit Mercado.Listed(TOKEN, alice, PRICE, expiresAt);
        vm.prank(alice);
        mercado.list(TOKEN, PRICE, expiresAt);

        Mercado.Listing memory listing = mercado.listingOf(TOKEN);
        assertEq(listing.seller, alice);
        assertEq(listing.price, PRICE);
        assertEq(listing.expiresAt, expiresAt);
        assertEq(listing.transferCount, 0);
        assertEq(listing.approvalsForAllRevoked, 0);
        assertEq(listing.tokenApprovalsRevoked, 0);
        // The NFT does not move: it stays with its holder until somebody buys it.
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_ListWorksWithAnApprovalForThatNftOnly() public {
        _sell(alice, TOKEN);
        vm.prank(alice);
        prenda.approve(address(mercado), TOKEN);

        vm.prank(alice);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));

        assertEq(mercado.listingOf(TOKEN).seller, alice);
    }

    function test_ListAgainChangesTheOffer() public {
        _sellAndList(alice, TOKEN, PRICE);
        uint48 newExpiry = uint48(start + 1 days);

        vm.expectEmit(address(mercado));
        emit Mercado.Listed(TOKEN, alice, 3 * PRICE, newExpiry);
        vm.prank(alice);
        mercado.list(TOKEN, 3 * PRICE, newExpiry);

        Mercado.Listing memory listing = mercado.listingOf(TOKEN);
        assertEq(listing.price, 3 * PRICE);
        assertEq(listing.expiresAt, newExpiry);
    }

    function test_ListRecordsHowManyTimesTheNftChangedHands() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);
        _approveMercado(bob);

        vm.prank(bob);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));

        assertEq(mercado.listingOf(TOKEN).transferCount, 1);
    }

    function test_ListWorksWhileSalesArePaused() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);
        vm.prank(admin);
        prenda.pause();

        vm.prank(alice);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));

        assertEq(mercado.listingOf(TOKEN).seller, alice);
    }

    /// @dev The offer records the two counts kept by the NFT contract: approvals for all taken back by the seller
    /// and approvals of that NFT taken back, each from this market.
    function test_ListRecordsHowManyApprovalsWereTakenBack() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        // One approval for all taken back...
        prenda.setApprovalForAll(address(mercado), true);
        prenda.setApprovalForAll(address(mercado), false);
        // ...and two approvals of the first NFT.
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(0), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(0), TOKEN);
        prenda.setApprovalForAll(address(mercado), true);

        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        mercado.list(TOKEN + 1, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();

        assertEq(mercado.listingOf(TOKEN).approvalsForAllRevoked, 1);
        assertEq(mercado.listingOf(TOKEN).tokenApprovalsRevoked, 2);
        assertEq(mercado.listingOf(TOKEN + 1).approvalsForAllRevoked, 1);
        assertEq(mercado.listingOf(TOKEN + 1).tokenApprovalsRevoked, 0);
    }

    /// @dev After the NFT left and came back, the seller offers it again and that new offer sells.
    function test_SellerCanOfferAgainAfterTheNftCameBack() public {
        _sellAndList(alice, TOKEN, PRICE);
        OpenMarketMock otherMarket = _anotherMarket();
        vm.prank(alice);
        prenda.setApprovalForAll(address(otherMarket), true);
        vm.prank(carol);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(alice, carol, TOKEN);
        otherMarket.move(carol, alice, TOKEN);

        vm.prank(alice);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        assertEq(mercado.listingOf(TOKEN).transferCount, 2);

        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    /// @dev The checks run before anything is written: a refused offer leaves the previous one untouched.
    function test_RefusedOfferLeavesThePreviousOneUntouched() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);
        uint48 expiresAt = uint48(start + 5 days);
        vm.startPrank(alice);
        mercado.list(TOKEN, PRICE, expiresAt);

        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceBelowMinimum.selector, MIN_PRICE - 1, MIN_PRICE));
        mercado.list(TOKEN, MIN_PRICE - 1, expiresAt);
        vm.stopPrank();

        Mercado.Listing memory listing = mercado.listingOf(TOKEN);
        assertEq(listing.price, PRICE);
        assertEq(listing.expiresAt, expiresAt);
    }

    /// @dev Changing an offer needs the approval of the market just like making it.
    function test_RevertWhen_ChangingAnOfferWithoutTheApproval() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(mercado), false);

        vm.expectRevert(abi.encodeWithSelector(Mercado.MarketNotApproved.selector, TOKEN));
        mercado.list(TOKEN, 2 * PRICE, uint48(start + 1 days));
        vm.stopPrank();

        assertEq(mercado.listingOf(TOKEN).price, PRICE);
    }

    /// @dev Once transfers are open a holder can approve anybody. Those accounts still cannot offer the NFT.
    function test_RevertWhen_AnAccountApprovedByTheHolderListsAfterTransfersAreOpened() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(admin);
        prenda.openTransfers();
        vm.startPrank(alice);
        prenda.approve(bob, TOKEN);
        prenda.setApprovalForAll(carol, true);
        vm.stopPrank();
        address[2] memory others = [bob, carol];

        for (uint256 i = 0; i < others.length; i++) {
            _approveMercado(others[i]);
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(Mercado.NotHolder.selector, TOKEN, others[i]));
            mercado.list(TOKEN, MIN_PRICE, uint48(start + 1 days));
        }

        // Alice's offer was not replaced.
        assertEq(mercado.listingOf(TOKEN).seller, alice);
        assertEq(mercado.listingOf(TOKEN).price, PRICE);
    }

    /// @dev A market that was switched off accepts no new offers: no approval counts for it any more.
    function test_RevertWhen_ListingOnAMarketThatWasDisabled() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        prenda.setApprovalForAll(address(mercado), true);
        vm.stopPrank();
        vm.prank(admin);
        prenda.disableMarket(address(mercado));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.MarketNotApproved.selector, TOKEN));
        mercado.list(TOKEN, PRICE, uint48(start + 1 days));
        vm.expectRevert(abi.encodeWithSelector(Mercado.MarketNotApproved.selector, TOKEN + 1));
        mercado.list(TOKEN + 1, PRICE, uint48(start + 1 days));
        vm.stopPrank();
    }

    function test_RevertWhen_SomeoneWhoIsNotTheHolderLists() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);
        _approveMercado(stranger);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotHolder.selector, TOKEN, stranger));
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotHolder.selector, TOKEN, admin));
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));

        _assertNoListing(TOKEN);
    }

    function test_RevertWhen_ListingAnNftThatDoesNotExist() public {
        _approveMercado(alice);

        vm.prank(alice);
        vm.expectRevert(_nonexistent(TOKEN));
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
    }

    function test_RevertWhen_ListingWithoutApprovingTheMarket() public {
        _sell(alice, TOKEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.MarketNotApproved.selector, TOKEN));
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));

        // An approval for another of her NFTs does not count.
        _sell(alice, TOKEN + 1);
        vm.prank(alice);
        prenda.approve(address(mercado), TOKEN + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.MarketNotApproved.selector, TOKEN));
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
    }

    function test_RevertWhen_ThePriceIsBelowTheMinimum() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceBelowMinimum.selector, MIN_PRICE - 1, MIN_PRICE));
        mercado.list(TOKEN, MIN_PRICE - 1, uint48(start + MAX_DURATION));
        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceBelowMinimum.selector, uint80(0), MIN_PRICE));
        mercado.list(TOKEN, 0, uint48(start + MAX_DURATION));

        mercado.list(TOKEN, MIN_PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        assertEq(mercado.listingOf(TOKEN).price, MIN_PRICE);
    }

    /// @dev The minimum price is compared to the unit, also when it is not a round number of tokens.
    function test_RevertWhen_ThePriceIsOneUnitBelowAMinimumThatIsNotRound() public {
        Mercado small = new Mercado(prenda, 1_500_000);
        vm.prank(admin);
        prenda.authorizeMarket(address(small));
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(small), true);

        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceBelowMinimum.selector, uint80(1_499_999), uint80(1_500_000)));
        small.list(TOKEN, 1_499_999, uint48(start + 1 days));
        small.list(TOKEN, 1_500_000, uint48(start + 1 days));
        vm.stopPrank();
    }

    function test_RevertWhen_TheOfferEndsInThePastOrTooFarAhead() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);
        vm.warp(start + 100);
        uint256 latest = block.timestamp + MAX_DURATION;

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.InvalidExpiry.selector, uint48(block.timestamp), latest));
        mercado.list(TOKEN, PRICE, uint48(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(Mercado.InvalidExpiry.selector, uint48(block.timestamp - 1), latest));
        mercado.list(TOKEN, PRICE, uint48(block.timestamp - 1));
        vm.expectRevert(abi.encodeWithSelector(Mercado.InvalidExpiry.selector, uint48(0), latest));
        mercado.list(TOKEN, PRICE, 0);
        vm.expectRevert(abi.encodeWithSelector(Mercado.InvalidExpiry.selector, uint48(latest + 1), latest));
        mercado.list(TOKEN, PRICE, uint48(latest + 1));

        // One second from now and exactly the longest time allowed are both fine.
        mercado.list(TOKEN, PRICE, uint48(block.timestamp + 1));
        mercado.list(TOKEN, PRICE, uint48(latest));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Withdrawing an offer
    // ------------------------------------------------------------------------------------------------------------

    function test_SellerCancelsTheOffer() public {
        _sellAndList(alice, TOKEN, PRICE);

        vm.expectEmit(address(mercado));
        emit Mercado.ListingCancelled(TOKEN, alice);
        vm.prank(alice);
        mercado.cancel(TOKEN);

        _assertNoListing(TOKEN);
        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotListed.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
    }

    function test_CancelWorksWhileSalesArePausedAndAfterTheOfferExpired() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(admin);
        prenda.pause();
        vm.warp(start + MAX_DURATION + 1 days);

        vm.prank(alice);
        mercado.cancel(TOKEN);

        _assertNoListing(TOKEN);
    }

    function test_RevertWhen_SomeoneElseCancelsTheOffer() public {
        _sellAndList(alice, TOKEN, PRICE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotSeller.selector, TOKEN, stranger));
        mercado.cancel(TOKEN);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotSeller.selector, TOKEN, admin));
        mercado.cancel(TOKEN);

        assertEq(mercado.listingOf(TOKEN).seller, alice);
    }

    /// @dev Only whoever made an offer withdraws it: not even the new holder of the NFT.
    function test_RevertWhen_TheNewHolderWithdrawsTheOfferOfThePreviousOne() public {
        _sellAndList(alice, TOKEN, PRICE);
        OpenMarketMock otherMarket = _anotherMarket();
        vm.prank(alice);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(alice, carol, TOKEN);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotSeller.selector, TOKEN, carol));
        mercado.cancel(TOKEN);

        assertEq(mercado.listingOf(TOKEN).seller, alice);
    }

    /// @dev An offer can be withdrawn after its garment was claimed and the NFT burned.
    function test_OfferOfAClaimedGarmentCanBeWithdrawn() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.startPrank(alice);
        prenda.claim(TOKEN, 0, ORDER);

        mercado.cancel(TOKEN);
        vm.stopPrank();

        _assertNoListing(TOKEN);
    }

    /// @dev Withdrawing needs no approval: it also works after the seller took the approval away.
    function test_WithdrawingAnOfferNeedsNoApproval() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(mercado), false);

        mercado.cancel(TOKEN);
        vm.stopPrank();

        _assertNoListing(TOKEN);
    }

    function test_RevertWhen_CancellingAnOfferThatDoesNotExist() public {
        _sell(alice, TOKEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotListed.selector, TOKEN));
        mercado.cancel(TOKEN);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Buying
    // ------------------------------------------------------------------------------------------------------------

    function test_BuySplitsThePriceAndMovesTheNft() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);

        vm.expectEmit(address(mercado));
        emit Mercado.Sold(TOKEN, alice, bob, PRICE, FEE);
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        // 100 USDT0: 98 to the seller, 2 to the treasury.
        assertEq(usdt.balanceOf(alice), 98 * 10 ** 6);
        assertEq(usdt.balanceOf(treasury), 2 * 10 ** 6);
        assertEq(usdt.balanceOf(bob), 0);
        assertEq(usdt.balanceOf(address(mercado)), 0);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(usdt.allowance(bob, address(mercado)), 0);
        assertEq(prenda.ownerOf(TOKEN), bob);
        assertEq(prenda.balanceOf(address(mercado)), 0);
        assertEq(prenda.transferCountOf(TOKEN), 1);
        _assertNoListing(TOKEN);
    }

    function test_BuyerCanClaimTheGarmentAndTheSellerCannot() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotTokenHolder.selector, TOKEN, alice));
        prenda.claim(TOKEN, 0, ORDER);
        vm.prank(bob);
        prenda.claim(TOKEN, 0, ORDER);

        assertEq(prenda.balanceOf(bob), 0);
    }

    function test_BuyWorksUntilTheLastSecondOfTheOffer() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.warp(start + MAX_DURATION);

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_BuyTakesOnlyThePriceWhenMoreWasApproved() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, 5 * uint256(PRICE));

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(usdt.balanceOf(bob), 4 * uint256(PRICE));
    }

    function test_FeeRoundsDownInFavourOfTheSeller() public {
        // 10.000049 USDT0: 2% is 0.20000098, which rounds down to 0.200000.
        uint80 price = 10_000_049;
        _sellAndList(alice, TOKEN, price);
        _fundAndApprove(bob, price);

        vm.expectEmit(address(mercado));
        emit Mercado.Sold(TOKEN, alice, bob, price, 200_000);
        vm.prank(bob);
        mercado.buy(TOKEN, price);

        assertEq(usdt.balanceOf(treasury), 200_000);
        assertEq(usdt.balanceOf(alice), 9_800_049);
    }

    /// @dev At the smallest minimum price a market can be deployed with, the fee is one unit, never zero.
    function test_FeeIsNeverZeroEvenAtTheSmallestPrice() public {
        Mercado smallest = new Mercado(prenda, 50);
        vm.prank(admin);
        prenda.authorizeMarket(address(smallest));
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.approve(address(smallest), TOKEN);
        smallest.list(TOKEN, 50, uint48(start + MAX_DURATION));
        vm.stopPrank();
        vm.startPrank(bob);
        usdt.mint(50);
        usdt.approve(address(smallest), 50);
        smallest.buy(TOKEN, 50);
        vm.stopPrank();

        assertEq(usdt.balanceOf(treasury), 1);
        assertEq(usdt.balanceOf(alice), 49);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_FeeGoesToTheTreasuryInForceAtThatMoment() public {
        address newTreasury = makeAddr("new treasury");
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.prank(admin);
        prenda.proposeTreasury(newTreasury);
        vm.prank(newTreasury);
        prenda.acceptTreasury();

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(usdt.balanceOf(newTreasury), FEE);
        assertEq(usdt.balanceOf(treasury), 0);
    }

    function test_MarketKeepsWorkingAfterTransfersAreOpened() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(admin);
        prenda.openTransfers();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_TheBuyerCanSellAgainAndTheNftKeepsMoving() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        _approveMercado(bob);
        vm.prank(bob);
        mercado.list(TOKEN, 2 * PRICE, uint48(start + MAX_DURATION));
        _fundAndApprove(carol, 2 * uint256(PRICE));
        vm.prank(carol);
        mercado.buy(TOKEN, 2 * uint256(PRICE));

        assertEq(prenda.ownerOf(TOKEN), carol);
        assertEq(prenda.transferCountOf(TOKEN), 2);
        // Alice got 98, bob paid 100 and got 196, the treasury got 2 + 4.
        assertEq(usdt.balanceOf(alice), 98 * 10 ** 6);
        assertEq(usdt.balanceOf(bob), 196 * 10 ** 6);
        assertEq(usdt.balanceOf(treasury), 6 * 10 ** 6);
    }

    /// @dev Pointless but harmless: the seller pays the 2% fee to the treasury and keeps the NFT.
    function test_SellerCanBuyTheirOwnOffer() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(alice), 98 * 10 ** 6);
        assertEq(usdt.balanceOf(treasury), FEE);
        _assertNoListing(TOKEN);
    }

    function test_RevertWhen_BuyingAnNftThatIsNotOnSale() public {
        _sell(alice, TOKEN);
        _approveMercado(alice);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotListed.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
    }

    function test_RevertWhen_TheOfferExpired() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.warp(start + MAX_DURATION + 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(Mercado.ListingExpired.selector, TOKEN, uint48(start + MAX_DURATION))
        );
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(bob), PRICE);
    }

    function test_RevertWhen_TheSellerChangedThePrice() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, 2 * uint256(PRICE));

        // Bob saw 100. Alice raises the price to 200 just before his purchase lands.
        vm.prank(alice);
        mercado.list(TOKEN, 2 * PRICE, uint48(start + MAX_DURATION));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceNotAsExpected.selector, TOKEN, 2 * PRICE, uint256(PRICE)));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(bob), 2 * uint256(PRICE));
    }

    /// @dev The seller lowers the price just before the purchase lands: the buyer stated another price, so the
    /// purchase does not go through either.
    function test_RevertWhen_TheSellerLoweredThePrice() public {
        _sellAndList(alice, TOKEN, 2 * PRICE);
        _fundAndApprove(bob, 2 * uint256(PRICE));
        vm.prank(alice);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceNotAsExpected.selector, TOKEN, PRICE, 2 * uint256(PRICE)));
        mercado.buy(TOKEN, 2 * uint256(PRICE));

        assertEq(usdt.balanceOf(bob), 2 * uint256(PRICE));
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev The stated price is compared in full, not after cutting it to the size of the stored price.
    function test_RevertWhen_TheStatedPriceOnlyMatchesInItsLowerBits() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        uint256 lookalike = uint256(PRICE) + (uint256(1) << 80);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.PriceNotAsExpected.selector, TOKEN, PRICE, lookalike));
        mercado.buy(TOKEN, lookalike);
    }

    function test_RevertWhen_TheNftWasSoldAnotherWay() public {
        // Alice offers it here, then sells it through another authorized market.
        _sellAndList(alice, TOKEN, PRICE);
        OpenMarketMock otherMarket = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(otherMarket));
        vm.prank(alice);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(alice, carol, TOKEN);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), carol);
        assertEq(usdt.balanceOf(bob), PRICE);
    }

    /// @dev An old offer must not come back to life when the NFT returns to whoever made it.
    function test_RevertWhen_TheNftLeftAndCameBackToTheSeller() public {
        _sellAndList(alice, TOKEN, PRICE);
        OpenMarketMock otherMarket = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(otherMarket));
        vm.prank(alice);
        prenda.setApprovalForAll(address(otherMarket), true);
        vm.prank(carol);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(alice, carol, TOKEN);
        otherMarket.move(carol, alice, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), alice);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_TheGarmentWasClaimed() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(alice);
        prenda.claim(TOKEN, 0, ORDER);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(_nonexistent(TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(usdt.balanceOf(bob), PRICE);
    }

    function test_NewHolderReplacesTheOfferOfThePreviousOne() public {
        // Alice's offer is left behind when she sells the NFT another way.
        _sellAndList(alice, TOKEN, PRICE);
        OpenMarketMock otherMarket = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(otherMarket));
        vm.prank(alice);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(alice, carol, TOKEN);

        _approveMercado(carol);
        vm.prank(carol);
        mercado.list(TOKEN, 3 * PRICE, uint48(start + MAX_DURATION));

        Mercado.Listing memory listing = mercado.listingOf(TOKEN);
        assertEq(listing.seller, carol);
        assertEq(listing.price, 3 * PRICE);
        assertEq(listing.transferCount, 1);
        // Alice can no longer withdraw an offer that is not hers.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Mercado.NotSeller.selector, TOKEN, alice));
        mercado.cancel(TOKEN);
    }

    function test_PreviousHolderCanWithdrawAnOfferLeftBehind() public {
        _sellAndList(alice, TOKEN, PRICE);
        OpenMarketMock otherMarket = new OpenMarketMock(prenda);
        vm.prank(admin);
        prenda.authorizeMarket(address(otherMarket));
        vm.prank(alice);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(alice, carol, TOKEN);

        vm.prank(alice);
        mercado.cancel(TOKEN);

        _assertNoListing(TOKEN);
    }

    // Taking an approval back from the market withdraws offers for good: the approval for all withdraws every offer
    // of the seller, the approval of one NFT withdraws the offer of that NFT.

    function test_RevertWhen_TheSellerTookTheApprovalBack() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        // Nobody paid anything. The offer is still recorded, but it is dead.
        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(treasury), 0);
        assertEq(mercado.listingOf(TOKEN).seller, alice);
    }

    /// @dev The offer does not come back to life when the seller approves the market again.
    function test_RevertWhen_TheSellerTookTheApprovalBackAndGaveItAgain() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        vm.warp(start + 20 days);
        _approveMercado(alice);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(bob), PRICE);
    }

    /**
     * @dev Alice takes garment 1 off the market by revoking the market in her wallet. Weeks later she approves the
     * market again only to sell another garment. The approval covers all her NFTs, but the old offer of garment 1
     * stays dead: nobody can take it at its old price before she sends anything else.
     */
    function test_RevertWhen_TheSellerApprovesTheMarketAgainToSellAnotherNft() public {
        _sellAndList(alice, TOKEN, PRICE);
        _sell(alice, TOKEN + 1);
        vm.prank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        vm.warp(start + 25 days);
        _approveMercado(alice);
        _fundAndApprove(bob, 2 * uint256(PRICE));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        // The garment she did mean to sell sells normally.
        vm.prank(alice);
        mercado.list(TOKEN + 1, PRICE, uint48(block.timestamp + 1 days));
        vm.prank(bob);
        mercado.buy(TOKEN + 1, PRICE);
        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.ownerOf(TOKEN + 1), bob);
    }

    /// @dev With an approval for the NFT and an approval for all, taking the approval for all back stops the
    /// offers, even though the market could still move both NFTs with their own approvals.
    function test_RevertWhen_TheOfferHadTwoApprovalsAndTheSellerTookTheOneForAllBack() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(mercado), TOKEN + 1);
        prenda.setApprovalForAll(address(mercado), true);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        mercado.list(TOKEN + 1, PRICE, uint48(start + MAX_DURATION));
        prenda.setApprovalForAll(address(mercado), false);
        vm.stopPrank();
        assertEq(prenda.getApproved(TOKEN), address(mercado));
        _fundAndApprove(bob, 2 * uint256(PRICE));

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN + 1));
        mercado.buy(TOKEN + 1, PRICE);
        vm.stopPrank();

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.ownerOf(TOKEN + 1), alice);
    }

    /// @dev The other way round: the approval of the NFT goes, the approval for all stays. The offer of that NFT
    /// stops; the offer of the seller's other NFT is not touched.
    function test_RevertWhen_TheOfferHadTwoApprovalsAndTheSellerTookTheOneOfTheNftBack() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(mercado), TOKEN + 1);
        prenda.setApprovalForAll(address(mercado), true);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        mercado.list(TOKEN + 1, PRICE, uint48(start + MAX_DURATION));
        prenda.approve(address(0), TOKEN);
        vm.stopPrank();
        assertTrue(prenda.isApprovedForAll(alice, address(mercado)));
        _fundAndApprove(bob, 2 * uint256(PRICE));

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
        mercado.buy(TOKEN + 1, PRICE);
        vm.stopPrank();

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.ownerOf(TOKEN + 1), bob);
    }

    /// @dev An offer made under an approval for that NFT only: clearing the approval withdraws it for good.
    function test_RevertWhen_TheSellerClearedTheApprovalOfTheNftAndGaveItAgain() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        prenda.approve(address(0), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        vm.stopPrank();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev The same when the approval of the NFT went to another market and came back.
    function test_RevertWhen_TheSellerGaveTheApprovalOfTheNftToAnotherMarketAndBack() public {
        OpenMarketMock otherMarket = _anotherMarket();
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        prenda.approve(address(otherMarket), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        vm.stopPrank();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev The same once transfers are open, where the approval of the NFT can also go to a wallet.
    function test_RevertWhen_TheSellerGaveTheApprovalOfTheNftToAWalletAndBackAfterTransfersAreOpened() public {
        _sell(alice, TOKEN);
        vm.prank(admin);
        prenda.openTransfers();
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        prenda.approve(carol, TOKEN);
        prenda.approve(address(mercado), TOKEN);
        vm.stopPrank();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev Taking back the approval of one NFT withdraws the offer of that NFT and no other.
    function test_TakingBackTheApprovalOfOneNftWithdrawsOnlyTheOfferOfThatNft() public {
        _sell(alice, TOKEN);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(mercado), TOKEN + 1);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        mercado.list(TOKEN + 1, PRICE, uint48(start + MAX_DURATION));
        prenda.approve(address(0), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        vm.stopPrank();
        _fundAndApprove(bob, 2 * uint256(PRICE));

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
        mercado.buy(TOKEN + 1, PRICE);
        vm.stopPrank();

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.ownerOf(TOKEN + 1), bob);
    }

    /// @dev An offer made under the approval for all is not touched when the seller clears the approval of
    /// another of their NFTs.
    function test_ClearingTheApprovalOfAnotherNftDoesNotTouchTheOffer() public {
        _sellAndList(alice, TOKEN, PRICE);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN + 1);
        prenda.approve(address(0), TOKEN + 1);
        vm.stopPrank();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    /// @dev An offer withdrawn by taking the approval back during a pause stays dead after the pause.
    function test_RevertWhen_TheSellerTookTheApprovalBackAndGaveItAgainDuringAPause() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(admin);
        prenda.pause();
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        prenda.setApprovalForAll(address(mercado), true);
        vm.stopPrank();
        vm.prank(admin);
        prenda.unpause();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev The counts are compared in full: 256 approvals taken back and given again do not bring an offer back.
    function test_RevertWhen_TheSellerTookTheApprovalBack256Times() public {
        _sellAndList(alice, TOKEN, PRICE);
        _sell(alice, TOKEN + 1);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN + 1);
        mercado.list(TOKEN + 1, PRICE, uint48(start + MAX_DURATION));
        for (uint256 i = 0; i < 256; i++) {
            prenda.setApprovalForAll(address(mercado), false);
            prenda.setApprovalForAll(address(mercado), true);
        }
        vm.stopPrank();
        assertEq(prenda.approvalsForAllRevoked(alice, address(mercado)), 256);
        _fundAndApprove(bob, PRICE);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN + 1));
        mercado.buy(TOKEN + 1, PRICE);
        vm.stopPrank();
    }

    function test_RevertWhen_TheSellerTookTheApprovalOfTheNftBack256Times() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        for (uint256 i = 0; i < 256; i++) {
            prenda.approve(address(0), TOKEN);
            prenda.approve(address(mercado), TOKEN);
        }
        vm.stopPrank();
        assertEq(prenda.tokenApprovalsRevoked(TOKEN, address(mercado)), 256);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
        mercado.buy(TOKEN, PRICE);
    }

    /// @dev After taking the approval back, a new approval and a new offer work as on the first day.
    function test_ANewOfferAfterTakingTheApprovalBackSells() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        _approveMercado(alice);
        vm.prank(alice);
        mercado.list(TOKEN, 2 * PRICE, uint48(start + MAX_DURATION));
        _fundAndApprove(bob, 2 * uint256(PRICE));

        vm.prank(bob);
        mercado.buy(TOKEN, 2 * uint256(PRICE));

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    /// @dev The same with the approval of the NFT: a new offer records the count as it is now, and sells.
    function test_ANewOfferAfterTakingTheApprovalOfTheNftBackSells() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        prenda.approve(address(0), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, 2 * PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        assertEq(mercado.listingOf(TOKEN).tokenApprovalsRevoked, 1);
        _fundAndApprove(bob, 2 * uint256(PRICE));

        vm.prank(bob);
        mercado.buy(TOKEN, 2 * uint256(PRICE));

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    /// @dev A seller that had taken approvals back before offers under an approval for one NFT: the offer sells.
    function test_OfferUnderAnApprovalForOneNftBySellerWhoTookApprovalsBackBeforeSells() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(mercado), true);
        prenda.setApprovalForAll(address(mercado), false);
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(0), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        assertEq(mercado.listingOf(TOKEN).approvalsForAllRevoked, 1);
        assertEq(mercado.listingOf(TOKEN).tokenApprovalsRevoked, 1);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    /// @dev An offer made while sales are paused by a seller that had taken approvals back sells after the pause.
    function test_OfferMadeDuringAPauseBySellerWhoTookApprovalsBackBeforeSells() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.setApprovalForAll(address(mercado), true);
        prenda.setApprovalForAll(address(mercado), false);
        prenda.setApprovalForAll(address(mercado), true);
        vm.stopPrank();
        vm.prank(admin);
        prenda.pause();
        vm.prank(alice);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.prank(admin);
        prenda.unpause();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    /// @dev The count of an NFT follows the NFT: what an earlier holder took back does not weigh on the offers of
    /// the next one.
    function test_OfferByANewHolderOfAnNftWhoseApprovalWasOnceTakenBackSells() public {
        _sell(alice, TOKEN);
        vm.startPrank(alice);
        prenda.approve(address(mercado), TOKEN);
        prenda.approve(address(0), TOKEN);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        vm.startPrank(bob);
        prenda.approve(address(mercado), TOKEN);
        mercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        assertEq(mercado.listingOf(TOKEN).tokenApprovalsRevoked, 1);
        assertEq(mercado.listingOf(TOKEN).approvalsForAllRevoked, 0);
        _fundAndApprove(carol, PRICE);
        vm.prank(carol);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), carol);
    }

    /// @dev What the seller does with other markets, or what other holders do with this one, changes nothing.
    function test_ApprovalsTakenBackElsewhereDoNotTouchTheOffer() public {
        _sellAndList(alice, TOKEN, PRICE);
        _sell(alice, TOKEN + 1);
        _sell(carol, TOKEN + 2);
        OpenMarketMock otherMarket = _anotherMarket();
        vm.startPrank(alice);
        // The seller, with another market: the approval for all, and the approval of the NFT on offer.
        prenda.setApprovalForAll(address(otherMarket), true);
        prenda.setApprovalForAll(address(otherMarket), false);
        prenda.approve(address(otherMarket), TOKEN);
        prenda.approve(address(0), TOKEN);
        vm.stopPrank();
        // Another holder, with this market: the approval for all, and the approval of an NFT of theirs.
        vm.startPrank(carol);
        prenda.setApprovalForAll(address(mercado), true);
        prenda.setApprovalForAll(address(mercado), false);
        prenda.approve(address(mercado), TOKEN + 2);
        prenda.approve(address(0), TOKEN + 2);
        vm.stopPrank();
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_BuyingWhileSalesArePaused() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.prank(admin);
        prenda.pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mercado.buy(TOKEN, PRICE);

        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(usdt.balanceOf(alice), 0);
        vm.prank(admin);
        prenda.unpause();
        vm.prank(bob);
        mercado.buy(TOKEN, PRICE);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_TheMarketWasDisabled() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, PRICE);
        vm.prank(admin);
        prenda.disableMarket(address(mercado));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Prenda.TransferNotAllowed.selector, address(mercado)));
        mercado.buy(TOKEN, PRICE);

        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_TheBuyerDidNotApproveThePrice() public {
        _sellAndList(alice, TOKEN, PRICE);
        _fundAndApprove(bob, uint256(PRICE) - 1);
        vm.prank(bob);
        usdt.mint(1);

        // One unit short: the seller's part goes through, the fee does not, and so nothing goes through.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(mercado), FEE - 1, FEE)
        );
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(mercado.listingOf(TOKEN).seller, alice);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(bob), PRICE);
    }

    /// @dev The buyer approved enough for the seller's part but not for the fee: nobody gets paid.
    function test_RevertWhen_TheBuyerApprovedEverythingButTheFee() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.startPrank(bob);
        usdt.mint(PRICE);
        usdt.approve(address(mercado), uint256(PRICE) - FEE);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(mercado), 0, FEE)
        );
        mercado.buy(TOKEN, PRICE);

        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_TheBuyerCannotPay() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(bob);
        usdt.approve(address(mercado), PRICE);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, uint256(PRICE) - FEE)
        );
        mercado.buy(TOKEN, PRICE);

        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function testFuzz_BuySplitsThePriceExactlyAndNothingStaysInTheContracts(uint80 price) public {
        price = uint80(bound(price, MIN_PRICE, 10_000 * 10 ** 6));
        _sellAndList(alice, TOKEN, price);
        _fundAndApprove(bob, price);

        vm.prank(bob);
        mercado.buy(TOKEN, price);

        uint256 fee = (uint256(price) * 2) / 100;
        assertEq(usdt.balanceOf(treasury), fee);
        assertEq(usdt.balanceOf(alice), price - fee);
        assertEq(usdt.balanceOf(alice) + usdt.balanceOf(treasury), price);
        assertGt(fee, 0);
        assertEq(usdt.balanceOf(bob), 0);
        assertEq(usdt.balanceOf(address(mercado)), 0);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    // ------------------------------------------------------------------------------------------------------------
    // A payment token that calls the buyer back, and one whose issuer blocks accounts
    // (models of what USDT0's issuer could do, not the real USDT0)
    // ------------------------------------------------------------------------------------------------------------

    function test_BuyerCannotTakeTheSameOfferTwiceFromInsideThePayment() public {
        CallbackTokenMock token = new CallbackTokenMock();
        (Prenda otherPrenda, OpenMinterMock otherMinter, Mercado otherMercado) = _deployWith(token);
        otherMinter.mint(alice, TOKEN, Prenda.StorageTerms(0, 0, 0), keccak256("data"));
        vm.startPrank(alice);
        otherPrenda.setApprovalForAll(address(otherMercado), true);
        otherMercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        ReentrantMarketBuyerMock buyer = new ReentrantMarketBuyerMock(otherMercado);
        token.mint(address(buyer), 2 * uint256(PRICE));

        buyer.buy(token, TOKEN, PRICE);

        assertTrue(buyer.callbackRan());
        assertFalse(buyer.secondPurchaseWorked());
        assertEq(otherPrenda.ownerOf(TOKEN), address(buyer));
        assertEq(token.balanceOf(alice), uint256(PRICE) - FEE);
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(token.balanceOf(address(buyer)), PRICE);
    }

    /// @dev A payment token that answers false instead of failing must not give the NFT away.
    function test_RevertWhen_ThePaymentTokenAnswersFalse() public {
        FalseReturningTokenMock token = new FalseReturningTokenMock();
        (Prenda otherPrenda, OpenMinterMock otherMinter, Mercado otherMercado) = _deployWith(IERC20(address(token)));
        otherMinter.mint(alice, TOKEN, Prenda.StorageTerms(0, 0, 0), keccak256("data"));
        vm.startPrank(alice);
        otherPrenda.setApprovalForAll(address(otherMercado), true);
        otherMercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();

        // Bob has neither the money nor an approval.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        otherMercado.buy(TOKEN, PRICE);
        assertEq(otherPrenda.ownerOf(TOKEN), alice);

        // Now he has enough for the seller's part, but not for the fee.
        token.mint(bob, uint256(PRICE) - FEE);
        vm.startPrank(bob);
        token.approve(address(otherMercado), PRICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        otherMercado.buy(TOKEN, PRICE);
        vm.stopPrank();

        assertEq(otherPrenda.ownerOf(TOKEN), alice);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), uint256(PRICE) - FEE);
    }

    function _blocklistSetup() internal returns (BlocklistTokenMock token, Mercado otherMercado, Prenda otherPrenda) {
        token = new BlocklistTokenMock();
        OpenMinterMock otherMinter;
        (otherPrenda, otherMinter, otherMercado) = _deployWith(token);
        otherMinter.mint(alice, TOKEN, Prenda.StorageTerms(0, 0, 0), keccak256("data"));
        vm.startPrank(alice);
        otherPrenda.setApprovalForAll(address(otherMercado), true);
        otherMercado.list(TOKEN, PRICE, uint48(start + MAX_DURATION));
        vm.stopPrank();
        token.mint(bob, PRICE);
        vm.prank(bob);
        token.approve(address(otherMercado), PRICE);
    }

    function test_BuyReachesASellerAndATreasuryThatTheIssuerBlocked() public {
        (BlocklistTokenMock token, Mercado otherMercado, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(alice, true);
        token.setBlocked(treasury, true);

        vm.prank(bob);
        otherMercado.buy(TOKEN, PRICE);

        assertEq(token.balanceOf(alice), uint256(PRICE) - FEE);
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(otherPrenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_TheIssuerBlockedTheBuyer() public {
        (BlocklistTokenMock token, Mercado otherMercado, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(bob, true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, bob));
        otherMercado.buy(TOKEN, PRICE);

        assertEq(otherPrenda.ownerOf(TOKEN), alice);
    }

    /// @dev A known limit: if the issuer blocks this market, its sales stop. The way out is a new market module.
    function test_RevertWhen_TheIssuerBlockedTheMarket() public {
        (BlocklistTokenMock token, Mercado otherMercado, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(address(otherMercado), true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, address(otherMercado)));
        otherMercado.buy(TOKEN, PRICE);

        assertEq(otherPrenda.ownerOf(TOKEN), alice);
        assertEq(token.balanceOf(bob), PRICE);
    }
}

/**
 * @notice One offer on the market against a simple model of when it can be taken (fourth review). The model has no
 * way back from "dead", so this also checks that no sequence revives an offer, and that nothing a third party does
 * kills it. It covers what the stateful tests of the three contracts do not: transfers opened, the approval of the
 * NFT given to a wallet, the market disabled. Random sequences of 32 steps out of 14 kinds of operation.
 */
contract MercadoOfferModelTest is Test {
    uint80 internal constant MIN_PRICE = 10 * 10 ** 6;
    uint80 internal constant PRICE = 100 * 10 ** 6;
    /// @dev The NFT on offer, held by alice, and an NFT of carol, a third party.
    uint256 internal constant X = 7;
    uint256 internal constant Y = 8;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    error Probe(bool ok);

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    Mercado internal mercado;
    OpenMarketMock internal otherMarket;

    // The model.
    bool internal approvesForAll; // alice approves the market for all her NFTs, as stored
    address internal approvedForX; // the approval of X, as stored
    bool internal dead; // a count moved, or X changed hands, since the offer
    bool internal paused;
    bool internal open;
    bool internal disabled;
    bool internal carolForAll;
    bool internal carolForY;

    function _setUp(uint256 seed) internal {
        usdt = new TestUSDT0();
        prenda = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, "");
        OpenMinterMock minter = new OpenMinterMock(prenda);
        mercado = new Mercado(prenda, MIN_PRICE);
        otherMarket = new OpenMarketMock(prenda);
        vm.startPrank(admin);
        prenda.setMinter(address(minter), true);
        prenda.authorizeMarket(address(mercado));
        prenda.authorizeMarket(address(otherMarket));
        vm.stopPrank();
        minter.mint(alice, X, Prenda.StorageTerms(0, 0, 0), keccak256("x"));
        minter.mint(carol, Y, Prenda.StorageTerms(0, 0, 0), keccak256("y"));

        // The offer is made under the approval for all, the one of X, or both.
        uint256 mode = seed % 3;
        vm.startPrank(alice);
        if (mode != 1) {
            prenda.setApprovalForAll(address(mercado), true);
            approvesForAll = true;
        }
        if (mode != 0) {
            prenda.approve(address(mercado), X);
            approvedForX = address(mercado);
        }
        mercado.list(X, PRICE, uint48(block.timestamp + 30 days));
        vm.stopPrank();

        vm.startPrank(bob);
        usdt.mint(PRICE);
        usdt.approve(address(mercado), PRICE);
        vm.stopPrank();
    }

    /// @dev Tries the purchase and always reverts, so that a purchase that works leaves no trace. The answer is
    /// in the revert.
    function probeBuy() external {
        vm.prank(bob);
        try mercado.buy(X, PRICE) {
            revert Probe(true);
        } catch {
            revert Probe(false);
        }
    }

    function _canBeTaken() internal returns (bool ok) {
        try this.probeBuy() {
            revert("unreachable");
        } catch (bytes memory reason) {
            require(bytes4(reason) == Probe.selector, "unexpected revert");
            assembly {
                ok := mload(add(reason, 36))
            }
        }
    }

    function _step(uint8 op) internal {
        op = op % 14;
        address m = address(mercado);
        if (op == 0) {
            vm.prank(alice);
            try prenda.setApprovalForAll(m, true) {
                approvesForAll = true;
            } catch {}
        } else if (op == 1) {
            vm.prank(alice);
            prenda.setApprovalForAll(m, false);
            if (approvesForAll) dead = true;
            approvesForAll = false;
        } else if (op == 2) {
            vm.prank(alice);
            try prenda.approve(m, X) {
                approvedForX = m;
            } catch {}
        } else if (op == 3) {
            vm.prank(alice);
            prenda.approve(address(0), X);
            if (approvedForX == m) dead = true;
            approvedForX = address(0);
        } else if (op == 4) {
            vm.prank(alice);
            try prenda.approve(address(otherMarket), X) {
                if (approvedForX == m) dead = true;
                approvedForX = address(otherMarket);
            } catch {}
        } else if (op == 5) {
            // X goes to dave through the other market and comes back.
            if (paused) return;
            vm.prank(alice);
            prenda.setApprovalForAll(address(otherMarket), true);
            vm.prank(dave);
            prenda.setApprovalForAll(address(otherMarket), true);
            otherMarket.move(alice, dave, X);
            otherMarket.move(dave, alice, X);
            dead = true;
            approvedForX = address(0);
        } else if (op == 6) {
            vm.prank(admin);
            if (paused) prenda.unpause();
            else prenda.pause();
            paused = !paused;
        } else if (op == 7) {
            vm.prank(carol);
            try prenda.setApprovalForAll(m, !carolForAll) {
                carolForAll = !carolForAll;
            } catch {}
        } else if (op == 8) {
            vm.prank(carol);
            try prenda.approve(carolForY ? address(0) : m, Y) {
                carolForY = !carolForY;
            } catch {}
        } else if (op == 9) {
            // A third party offers its own NFT, and somebody takes back what they never gave.
            vm.prank(carol);
            try mercado.list(Y, PRICE, uint48(block.timestamp + 1 days)) {} catch {}
            vm.prank(bob);
            prenda.setApprovalForAll(m, false);
        } else if (op == 10) {
            if (open) return;
            vm.prank(admin);
            prenda.openTransfers();
            open = true;
        } else if (op == 11) {
            // Once transfers are open the approval of X can go to a wallet.
            vm.prank(alice);
            try prenda.approve(dave, X) {
                if (approvedForX == m) dead = true;
                approvedForX = dave;
            } catch {}
        } else if (op == 12) {
            // Third parties try to clear the approval of X.
            vm.prank(dave);
            try prenda.approve(address(0), X) {
                revert("a third party cleared the approval of X");
            } catch {}
            vm.prank(address(otherMarket));
            try prenda.approve(address(0), X) {
                revert("a market cleared the approval of X");
            } catch {}
        } else {
            // Now and then the market is disabled for good.
            if (disabled || uint256(keccak256(abi.encode(op, block.timestamp, approvedForX))) % 3 != 0) return;
            vm.prank(admin);
            prenda.disableMarket(m);
            disabled = true;
        }
    }

    function testFuzz_AnOfferCanBeTakenExactlyWhenTheModelSaysSoAndNeverRevives(uint256 seed) public {
        _setUp(seed);
        bool everRefused;
        for (uint256 i = 0; i < 32; i++) {
            _step(uint8(seed >> (8 * i)));
            if (paused) continue;
            bool ok = _canBeTaken();
            bool expected = !dead && !disabled && (approvesForAll || approvedForX == address(mercado));
            assertEq(ok, expected, "the offer is not as the model says");
            if (everRefused) assertFalse(ok, "an offer came back");
            if (!ok) everRefused = true;
        }
    }
}
