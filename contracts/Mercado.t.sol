// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Mercado} from "./Mercado.sol";
import {Prenda} from "./Prenda.sol";
import {ReentrantMarketBuyerMock} from "./mocks/BuyerMocks.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {OpenMinterMock} from "./mocks/OpenMinterMock.sol";
import {BlocklistTokenMock, CallbackTokenMock} from "./mocks/PaymentTokenMocks.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

contract MercadoTest is Test {
    uint80 internal constant MIN_PRICE = 10 * 10 ** 6;
    uint48 internal constant MAX_DURATION = 30 days;
    uint80 internal constant PRICE = 100 * 10 ** 6;
    uint256 internal constant FEE = 2 * 10 ** 6;
    uint256 internal constant TOKEN = 1;

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
        newMercado = new Mercado(newPrenda, MIN_PRICE, MAX_DURATION);
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
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function test_DeploymentRecordsTheSetup() public view {
        assertEq(address(mercado.prenda()), address(prenda));
        assertEq(address(mercado.paymentToken()), address(usdt));
        assertEq(mercado.minPrice(), MIN_PRICE);
        assertEq(mercado.maxListingDuration(), MAX_DURATION);
        assertEq(mercado.FEE_BPS(), 200);
        assertEq(uint8(prenda.marketStatus(address(mercado))), uint8(Prenda.MarketStatus.Authorized));
    }

    function test_RevertWhen_MinimumPriceWouldLetTheFeeRoundToZero() public {
        vm.expectRevert(abi.encodeWithSelector(Mercado.MinimumPriceTooLow.selector, uint80(49)));
        new Mercado(prenda, 49, MAX_DURATION);
        vm.expectRevert(abi.encodeWithSelector(Mercado.MinimumPriceTooLow.selector, uint80(0)));
        new Mercado(prenda, 0, MAX_DURATION);

        // With 50 units the fee is exactly one unit.
        Mercado smallest = new Mercado(prenda, 50, MAX_DURATION);
        assertEq(smallest.minPrice(), 50);
    }

    function test_RevertWhen_OffersCouldNotLastAtAll() public {
        vm.expectRevert(Mercado.ZeroListingDuration.selector);
        new Mercado(prenda, MIN_PRICE, 0);
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
        prenda.claim(TOKEN, 0);
        vm.prank(bob);
        prenda.claim(TOKEN, 0);

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
        Mercado smallest = new Mercado(prenda, 50, MAX_DURATION);
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
        prenda.setTreasury(newTreasury);

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
        prenda.claim(TOKEN, 0);
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

    function test_RevertWhen_TheSellerRevokedTheApproval() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(mercado), TOKEN)
        );
        mercado.buy(TOKEN, PRICE);

        // Nobody paid anything and the offer is still recorded.
        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(treasury), 0);
        assertEq(mercado.listingOf(TOKEN).seller, alice);
    }

    /**
     * @dev A known limit, kept visible on purpose: an offer stays recorded until it is withdrawn, expires or the
     * NFT changes hands. If the seller takes the approval away and gives it back later, the offer can be taken
     * again at its old price. That is why offers expire and why the site shows the seller every open offer.
     */
    function test_AnOfferLeftOpenCanBeTakenAgainIfTheSellerRestoresTheApproval() public {
        _sellAndList(alice, TOKEN, PRICE);
        vm.prank(alice);
        prenda.setApprovalForAll(address(mercado), false);
        vm.warp(start + 20 days);
        _approveMercado(alice);
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
