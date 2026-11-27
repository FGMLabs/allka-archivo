// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {Mercado} from "./Mercado.sol";
import {Prenda} from "./Prenda.sol";
import {Venta} from "./Venta.sol";
import {BuyerAttackerMock, SellerAttackerMock} from "./mocks/AttackerMocks.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {OpenMinterMock} from "./mocks/OpenMinterMock.sol";
import {HookTokenMock} from "./mocks/PaymentTokenMocks.sol";

/**
 * @notice What a seller or a buyer could do if the payment token handed them control in the middle of a purchase.
 * USDT0 does not do that today, but its issuer can upgrade it. Here the payment token calls the payer and the
 * receiver, before and after the tokens move, and each of them tries everything it can. Every case must end in
 * one of two ways: nothing happened at all, or exactly one payment was made for exactly one NFT.
 *
 * The moments of a payment are numbered as in ITransferHook: 1 the payer before the tokens move, 2 the receiver
 * before, 3 the payer after, 4 the receiver after.
 */
contract ReentrancyTest is Test {
    uint48 internal constant DELAY = 24 hours;
    uint48 internal constant EARLY_WINDOW = 6 hours;
    uint80 internal constant MIN_PRICE = 10 * 10 ** 6;
    uint80 internal constant MAX_STORAGE = 100 * 10 ** 6;
    uint80 internal constant PRICE = 120 * 10 ** 6;
    uint256 internal constant FEE = (uint256(PRICE) * 2) / 100;
    uint48 internal constant MAX_DURATION = 30 days;
    uint256 internal constant TOKEN = 1;
    /// @dev Id of the first drop of a sale module.
    uint32 internal constant DROP = 1;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev The three contracts, a second authorized market and a sale module with no rules of its own.
    struct System {
        HookTokenMock token;
        Prenda prenda;
        Venta venta;
        Mercado mercado;
        OpenMarketMock otherMarket;
        OpenMinterMock minter;
    }

    function _deploy() internal returns (System memory s) {
        s.token = new HookTokenMock();
        s.prenda = new Prenda("Allka Archivo", "ALLKA", s.token, treasury, admin, "https://example.test/nft/");
        s.venta = new Venta(s.prenda, operator, DELAY, MIN_PRICE, MAX_STORAGE);
        s.mercado = new Mercado(s.prenda, MIN_PRICE);
        s.otherMarket = new OpenMarketMock(s.prenda);
        s.minter = new OpenMinterMock(s.prenda);
        vm.startPrank(admin);
        s.prenda.setMinter(address(s.venta), true);
        s.prenda.setMinter(address(s.minter), true);
        s.prenda.authorizeMarket(address(s.mercado));
        s.prenda.authorizeMarket(address(s.otherMarket));
        vm.stopPrank();
    }

    function _noStorageFee() internal pure returns (Prenda.StorageTerms memory) {
        return Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0});
    }

    function _items(uint256 count) internal pure returns (Venta.NewItem[] memory items) {
        items = new Venta.NewItem[](count);
        for (uint256 i = 0; i < count; i++) {
            items[i] = Venta.NewItem({tokenId: TOKEN + i, price: PRICE, contentHash: keccak256(abi.encode(TOKEN + i))});
        }
    }

    function _leaf(address account) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    // ------------------------------------------------------------------------------------------------------------
    // The seller of a resale acts while it is being paid
    // ------------------------------------------------------------------------------------------------------------

    /// @dev A seller that is a contract offers the NFT; bob has the money ready; the seller acts at `phase`.
    function _sellerSetup(
        SellerAttackerMock.Action action,
        uint8 phase
    ) internal returns (System memory s, SellerAttackerMock seller) {
        s = _deploy();
        seller = new SellerAttackerMock(s.prenda, s.mercado, s.otherMarket, carol);
        s.minter.mint(address(seller), TOKEN, _noStorageFee(), keccak256("data"));
        seller.prepare(TOKEN, PRICE, uint48(block.timestamp + MAX_DURATION));
        seller.arm(action, phase);
        s.token.setHooked(address(seller), true);
        s.token.mint(bob, PRICE);
        vm.prank(bob);
        s.token.approve(address(s.mercado), PRICE);
        // The accomplice lets both markets move what it holds: the worst case for the buyer.
        vm.startPrank(carol);
        s.prenda.setApprovalForAll(address(s.otherMarket), true);
        s.prenda.setApprovalForAll(address(s.mercado), true);
        vm.stopPrank();
    }

    function _assertNothingHappened(System memory s, SellerAttackerMock seller) internal view {
        assertEq(s.prenda.ownerOf(TOKEN), address(seller), "the NFT is still the seller's");
        assertEq(s.prenda.transferCountOf(TOKEN), 0);
        assertEq(s.token.balanceOf(bob), PRICE, "the buyer kept the money");
        assertEq(s.token.balanceOf(address(seller)), 0, "the seller got nothing");
        assertEq(s.token.balanceOf(treasury), 0);
        assertEq(s.mercado.listingOf(TOKEN).seller, address(seller), "the offer is still recorded");
    }

    /// @dev The seller claims the garment, burning the NFT, while it is being paid: it must not end up with the
    /// money and the garment.
    function test_RevertWhen_TheSellerClaimsTheGarmentWhileBeingPaid() public {
        for (uint8 phase = 2; phase <= 4; phase += 2) {
            (System memory s, SellerAttackerMock seller) = _sellerSetup(SellerAttackerMock.Action.Claim, phase);

            // This error shows that the claim inside the payment did burn the NFT. The purchase then undoes it all.
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, TOKEN));
            s.mercado.buy(TOKEN, PRICE);

            _assertNothingHappened(s, seller);
        }
    }

    function test_RevertWhen_TheSellerTakesTheApprovalBackWhileBeingPaid() public {
        for (uint8 phase = 2; phase <= 4; phase += 2) {
            (System memory s, SellerAttackerMock seller) = _sellerSetup(SellerAttackerMock.Action.Revoke, phase);

            vm.prank(bob);
            vm.expectRevert(
                abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(s.mercado), TOKEN)
            );
            s.mercado.buy(TOKEN, PRICE);

            _assertNothingHappened(s, seller);
        }
    }

    /// @dev The seller hands the NFT to an accomplice while being paid. Even though the accomplice approved the
    /// market, the NFT is not taken from the accomplice and the buyer is not charged.
    function test_RevertWhen_TheSellerMovesTheNftAwayWhileBeingPaid() public {
        for (uint8 phase = 2; phase <= 4; phase += 2) {
            (System memory s, SellerAttackerMock seller) = _sellerSetup(SellerAttackerMock.Action.MoveAway, phase);

            vm.prank(bob);
            vm.expectRevert(
                abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, address(seller), TOKEN, carol)
            );
            s.mercado.buy(TOKEN, PRICE);

            _assertNothingHappened(s, seller);
        }
    }

    /// @dev The NFT leaves and comes back inside the payment: the buyer still gets it and pays the price once.
    function test_SellerMovingTheNftAwayAndBackWhileBeingPaidChangesNothing() public {
        for (uint8 phase = 2; phase <= 4; phase += 2) {
            (System memory s, SellerAttackerMock seller) = _sellerSetup(
                SellerAttackerMock.Action.MoveAwayAndBack,
                phase
            );

            vm.prank(bob);
            s.mercado.buy(TOKEN, PRICE);

            assertTrue(seller.hookRan());
            assertTrue(seller.actionWorked());
            assertEq(s.prenda.ownerOf(TOKEN), bob);
            assertEq(s.prenda.transferCountOf(TOKEN), 3);
            assertEq(s.token.balanceOf(bob), 0);
            assertEq(s.token.balanceOf(address(seller)), uint256(PRICE) - FEE);
            assertEq(s.token.balanceOf(treasury), FEE);
            assertEq(s.token.balanceOf(address(s.mercado)), 0);
        }
    }

    /// @dev The seller offers the NFT again from inside the payment. The new offer is recorded but can never be
    /// taken: the NFT changes hands right after.
    function test_OfferMadeByTheSellerWhileBeingPaidIsDead() public {
        for (uint8 phase = 2; phase <= 4; phase += 2) {
            (System memory s, SellerAttackerMock seller) = _sellerSetup(SellerAttackerMock.Action.Relist, phase);

            vm.prank(bob);
            s.mercado.buy(TOKEN, PRICE);

            assertTrue(seller.actionWorked());
            assertEq(seller.holderSeenInHook(), address(seller), "money first: the NFT had not moved yet");
            assertEq(seller.balanceSeenInHook(), phase == 2 ? 0 : uint256(PRICE) - FEE);
            assertEq(s.prenda.ownerOf(TOKEN), bob);
            assertEq(s.token.balanceOf(address(seller)), uint256(PRICE) - FEE);

            // The offer left behind cannot take bob's NFT, even though bob approves the market.
            vm.prank(bob);
            s.prenda.setApprovalForAll(address(s.mercado), true);
            assertEq(s.mercado.listingOf(TOKEN).seller, address(seller));
            s.token.mint(carol, MIN_PRICE);
            vm.startPrank(carol);
            s.token.approve(address(s.mercado), MIN_PRICE);
            vm.expectRevert(abi.encodeWithSelector(Mercado.ListingNoLongerValid.selector, TOKEN));
            s.mercado.buy(TOKEN, MIN_PRICE);
            vm.stopPrank();
            assertEq(s.prenda.ownerOf(TOKEN), bob);
        }
    }

    /// @dev By the time the seller is paid the offer is already gone: there is nothing left to withdraw.
    function test_SellerCannotWithdrawTheOfferWhileBeingPaid() public {
        (System memory s, SellerAttackerMock seller) = _sellerSetup(SellerAttackerMock.Action.Cancel, 2);

        vm.prank(bob);
        s.mercado.buy(TOKEN, PRICE);

        assertTrue(seller.hookRan());
        assertFalse(seller.actionWorked());
        assertEq(bytes4(seller.actionError()), Mercado.NotListed.selector);
        assertEq(s.prenda.ownerOf(TOKEN), bob);
        assertEq(s.token.balanceOf(address(seller)), uint256(PRICE) - FEE);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The buyer acts while it pays
    // ------------------------------------------------------------------------------------------------------------

    /// @dev A buyer that is a contract, with money for three garments, in front of a drop with two garments.
    function _buyerSetup(
        bool withEarlyWindow,
        uint8 phase
    ) internal returns (System memory s, BuyerAttackerMock buyer, bytes32[] memory proof) {
        s = _deploy();
        buyer = new BuyerAttackerMock(s.prenda, s.venta, s.mercado, IERC20(address(s.token)));
        buyer.arm(phase);
        buyer.approveMarket();
        s.token.setHooked(address(buyer), true);
        s.token.mint(address(buyer), 3 * uint256(PRICE));

        uint48 start = uint48(block.timestamp + DELAY);
        vm.prank(operator);
        if (withEarlyWindow) {
            // A snapshot with two wallets: the buyer and alice.
            bytes32 root = Hashes.commutativeKeccak256(_leaf(address(buyer)), _leaf(alice));
            s.venta.createDrop(start, start + EARLY_WINDOW, root, _noStorageFee(), _items(2));
            proof = new bytes32[](1);
            proof[0] = _leaf(alice);
        } else {
            s.venta.createDrop(start, start, bytes32(0), _noStorageFee(), _items(2));
            proof = new bytes32[](0);
        }
        vm.warp(start);
    }

    /// @dev First sale: money first, NFT second. Inside the payment the NFT does not exist yet, so it can be
    /// neither claimed nor offered, and the same garment cannot be bought twice.
    function test_BuyerGainsNothingFromInsideThePaymentOfAFirstSale() public {
        for (uint8 phase = 1; phase <= 3; phase += 2) {
            (System memory s, BuyerAttackerMock buyer, bytes32[] memory proof) = _buyerSetup(false, phase);

            buyer.buyFromVenta(TOKEN, DROP, PRICE, proof, TOKEN + 1, PRICE);

            assertTrue(buyer.hookRan());
            assertFalse(buyer.nftExistedInHook(), "money first: no NFT during the payment");
            assertFalse(buyer.sameAgainWorked());
            assertFalse(buyer.claimWorked());
            assertFalse(buyer.listWorked());
            // Buying another garment from inside the payment is just a second purchase, paid in full.
            assertTrue(buyer.otherWorked());
            assertEq(s.prenda.balanceOf(address(buyer)), 2);
            assertEq(s.token.balanceOf(treasury), 2 * uint256(PRICE));
            assertEq(s.token.balanceOf(address(buyer)), PRICE);
            assertEq(s.token.balanceOf(address(s.venta)), 0);
        }
    }

    function test_BuyerGetsNoSecondEarlyTurnFromInsideThePayment() public {
        for (uint8 phase = 1; phase <= 3; phase += 2) {
            (System memory s, BuyerAttackerMock buyer, bytes32[] memory proof) = _buyerSetup(true, phase);

            buyer.buyFromVenta(TOKEN, DROP, PRICE, proof, TOKEN + 1, PRICE);

            assertTrue(buyer.hookRan());
            assertFalse(buyer.nftExistedInHook());
            assertFalse(buyer.sameAgainWorked());
            assertFalse(buyer.otherWorked(), "no second early turn");
            assertFalse(buyer.claimWorked());
            assertFalse(buyer.listWorked());
            assertEq(s.prenda.balanceOf(address(buyer)), 1);
            assertFalse(s.prenda.isTokenIdUsed(TOKEN + 1));
            assertEq(s.token.balanceOf(treasury), PRICE);
            assertEq(s.token.balanceOf(address(buyer)), 2 * uint256(PRICE));
        }
    }

    /// @dev Resale: money first, NFT second. Inside the payment the NFT is still the seller's.
    function test_BuyerGainsNothingFromInsideThePaymentOfAResale() public {
        for (uint8 phase = 1; phase <= 3; phase += 2) {
            System memory s = _deploy();
            s.minter.mint(alice, TOKEN, _noStorageFee(), keccak256("data"));
            vm.startPrank(alice);
            s.prenda.setApprovalForAll(address(s.mercado), true);
            s.mercado.list(TOKEN, PRICE, uint48(block.timestamp + MAX_DURATION));
            vm.stopPrank();
            BuyerAttackerMock buyer = new BuyerAttackerMock(s.prenda, s.venta, s.mercado, IERC20(address(s.token)));
            buyer.arm(phase);
            buyer.approveMarket();
            s.token.setHooked(address(buyer), true);
            s.token.mint(address(buyer), 2 * uint256(PRICE));

            buyer.buyFromMercado(TOKEN, PRICE);

            assertTrue(buyer.hookRan());
            assertEq(buyer.holderSeenInHook(), alice, "money first: the NFT had not moved yet");
            assertFalse(buyer.sameAgainWorked());
            assertFalse(buyer.claimWorked());
            assertFalse(buyer.listWorked());
            assertEq(s.prenda.ownerOf(TOKEN), address(buyer));
            assertEq(s.token.balanceOf(alice), uint256(PRICE) - FEE);
            assertEq(s.token.balanceOf(treasury), FEE);
            assertEq(s.token.balanceOf(address(buyer)), PRICE);
            assertEq(s.token.balanceOf(address(s.mercado)), 0);
        }
    }
}
