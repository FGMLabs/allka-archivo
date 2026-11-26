// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Prenda} from "./Prenda.sol";
import {Venta} from "./Venta.sol";
import {ReentrantSaleBuyerMock} from "./mocks/BuyerMocks.sol";
import {OpenMinterMock} from "./mocks/OpenMinterMock.sol";
import {BlocklistTokenMock, CallbackTokenMock} from "./mocks/PaymentTokenMocks.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

contract VentaTest is Test {
    uint48 internal constant DELAY = 24 hours;
    uint48 internal constant EARLY_WINDOW = 6 hours;
    uint80 internal constant MIN_PRICE = 10 * 10 ** 6;
    uint80 internal constant MAX_STORAGE = 100 * 10 ** 6;
    uint80 internal constant PRICE = 120 * 10 ** 6;
    uint32 internal constant FREE_PERIOD = 180 days;
    uint80 internal constant FEE = 5 * 10 ** 6;
    uint80 internal constant MAX_FEE = 30 * 10 ** 6;
    uint256 internal constant TOKEN = 1;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal stranger = makeAddr("stranger");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    Venta internal venta;

    /// @dev Moment at which the drops of these tests are created.
    uint256 internal createdAt;

    function setUp() public {
        usdt = new TestUSDT0();
        (prenda, venta) = _deployWith(usdt);
        createdAt = block.timestamp;
    }

    function _deployWith(IERC20 paymentToken) internal returns (Prenda newPrenda, Venta newVenta) {
        newPrenda = new Prenda("Allka Archivo", "ALLKA", paymentToken, treasury, admin, "https://example.test/nft/");
        newVenta = new Venta(newPrenda, operator, DELAY, MIN_PRICE, MAX_STORAGE);
        vm.prank(admin);
        newPrenda.setMinter(address(newVenta), true);
    }

    function _terms() internal pure returns (Prenda.StorageTerms memory) {
        return Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: MAX_FEE});
    }

    function _hashOf(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encode("data of garment", tokenId));
    }

    /// @dev `count` garments numbered from `firstId`, all at the same price.
    function _items(uint256 firstId, uint256 count, uint80 price) internal pure returns (Venta.NewItem[] memory items) {
        items = new Venta.NewItem[](count);
        for (uint256 i = 0; i < count; i++) {
            items[i] = Venta.NewItem({tokenId: firstId + i, price: price, contentHash: _hashOf(firstId + i)});
        }
    }

    /// @dev A drop with no early window that opens as soon as the contract allows.
    function _createDrop(uint256 firstId, uint256 count) internal returns (uint32 dropId) {
        uint48 start = uint48(block.timestamp + DELAY);
        vm.prank(operator);
        dropId = venta.createDrop(start, start, bytes32(0), _terms(), _items(firstId, count, PRICE));
    }

    /// @dev A drop that opens first for alice, bob, carol and dave, and six hours later for everybody.
    function _createEarlyDrop(uint256 firstId, uint256 count) internal returns (uint32 dropId) {
        uint48 earlyStart = uint48(block.timestamp + DELAY);
        vm.prank(operator);
        dropId = venta.createDrop(
            earlyStart,
            earlyStart + EARLY_WINDOW,
            _root(),
            _terms(),
            _items(firstId, count, PRICE)
        );
    }

    // A snapshot with four wallets, built the way OpenZeppelin's merkle-tree library builds it.

    function _leaf(address account) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    function _root() internal view returns (bytes32) {
        return
            Hashes.commutativeKeccak256(
                Hashes.commutativeKeccak256(_leaf(alice), _leaf(bob)),
                Hashes.commutativeKeccak256(_leaf(carol), _leaf(dave))
            );
    }

    function _proofOf(address account) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        if (account == alice || account == bob) {
            proof[0] = _leaf(account == alice ? bob : alice);
            proof[1] = Hashes.commutativeKeccak256(_leaf(carol), _leaf(dave));
        } else {
            proof[0] = _leaf(account == carol ? dave : carol);
            proof[1] = Hashes.commutativeKeccak256(_leaf(alice), _leaf(bob));
        }
    }

    function _noProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /// @dev Gives `account` exactly `amount` test USDT0 and approves the sale contract for exactly that amount.
    function _fundAndApprove(address account, uint256 amount) internal {
        vm.startPrank(account);
        usdt.mint(amount);
        usdt.approve(address(venta), amount);
        vm.stopPrank();
    }

    function _buy(address buyer, uint256 tokenId) internal {
        _fundAndApprove(buyer, PRICE);
        vm.prank(buyer);
        venta.buy(tokenId, PRICE, _noProof());
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function test_DeploymentRecordsTheSetup() public view {
        assertEq(address(venta.prenda()), address(prenda));
        assertEq(address(venta.paymentToken()), address(usdt));
        assertEq(venta.operator(), operator);
        assertEq(venta.openingDelay(), DELAY);
        assertEq(venta.minPrice(), MIN_PRICE);
        assertEq(venta.maxStorageFee(), MAX_STORAGE);
        assertEq(venta.dropCount(), 0);
        assertTrue(prenda.isMinter(address(venta)));
    }

    function test_RevertWhen_MinimumPriceIsZero() public {
        vm.expectRevert(Venta.ZeroMinimumPrice.selector);
        new Venta(prenda, operator, DELAY, 0, MAX_STORAGE);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Creating a drop
    // ------------------------------------------------------------------------------------------------------------

    function test_CreateDropRecordsTheDropAndItsGarments() public {
        uint48 earlyStart = uint48(createdAt + DELAY);
        uint48 publicStart = earlyStart + EARLY_WINDOW;
        Venta.NewItem[] memory items = new Venta.NewItem[](2);
        items[0] = Venta.NewItem({tokenId: 7, price: PRICE, contentHash: _hashOf(7)});
        items[1] = Venta.NewItem({tokenId: 9, price: 2 * PRICE, contentHash: _hashOf(9)});

        vm.expectEmit(address(venta));
        emit Venta.DropCreated(1, earlyStart, publicStart, _root(), FREE_PERIOD, FEE, MAX_FEE);
        vm.expectEmit(address(venta));
        emit Venta.ItemAdded(1, 7, PRICE, _hashOf(7));
        vm.expectEmit(address(venta));
        emit Venta.ItemAdded(1, 9, 2 * PRICE, _hashOf(9));
        vm.prank(operator);
        uint32 dropId = venta.createDrop(earlyStart, publicStart, _root(), _terms(), items);

        assertEq(dropId, 1);
        assertEq(venta.dropCount(), 1);
        Venta.Drop memory drop = venta.dropOf(1);
        assertEq(drop.earlyStart, earlyStart);
        assertEq(drop.publicStart, publicStart);
        assertEq(drop.earlyRoot, _root());
        assertEq(drop.freePeriod, FREE_PERIOD);
        assertEq(drop.feePerPeriod, FEE);
        assertEq(drop.maxFee, MAX_FEE);
        assertFalse(drop.cancelled);

        (uint32 itemDrop, uint80 price, bool sold, bytes32 contentHash) = venta.itemOf(9);
        assertEq(itemDrop, 1);
        assertEq(price, 2 * PRICE);
        assertFalse(sold);
        assertEq(contentHash, _hashOf(9));

        // Creating a drop creates no NFT.
        assertFalse(prenda.isTokenIdUsed(7));
        assertFalse(prenda.isTokenIdUsed(9));
    }

    function test_DropIdsCountUp() public {
        assertEq(_createDrop(1, 1), 1);
        assertEq(_createDrop(2, 3), 2);
        assertEq(_createEarlyDrop(5, 1), 3);
        assertEq(venta.dropCount(), 3);
    }

    function test_UnknownDropAndGarmentHaveNoRecord() public view {
        Venta.Drop memory drop = venta.dropOf(1);
        assertEq(drop.earlyStart, 0);
        assertEq(drop.publicStart, 0);
        (uint32 itemDrop, uint80 price, bool sold, bytes32 contentHash) = venta.itemOf(TOKEN);
        assertEq(itemDrop, 0);
        assertEq(price, 0);
        assertFalse(sold);
        assertEq(contentHash, bytes32(0));
    }

    function test_RevertWhen_SomeoneElseCreatesADrop() public {
        uint48 start = uint48(createdAt + DELAY);
        address[3] memory callers = [stranger, admin, treasury];

        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Venta.NotOperator.selector, callers[i]));
            venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        }
    }

    function test_RevertWhen_DropHasNoGarments() public {
        uint48 start = uint48(createdAt + DELAY);

        vm.prank(operator);
        vm.expectRevert(Venta.EmptyDrop.selector);
        venta.createDrop(start, start, bytes32(0), _terms(), new Venta.NewItem[](0));
    }

    function test_RevertWhen_DropOpensTooSoon() public {
        uint48 tooSoon = uint48(createdAt + DELAY - 1);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.OpensTooSoon.selector, tooSoon, createdAt + DELAY));
        venta.createDrop(tooSoon, tooSoon, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        // An early window does not get around the delay either.
        vm.expectRevert(abi.encodeWithSelector(Venta.OpensTooSoon.selector, tooSoon, createdAt + DELAY));
        venta.createDrop(tooSoon, tooSoon + EARLY_WINDOW, _root(), _terms(), _items(TOKEN, 1, PRICE));
        vm.expectRevert(abi.encodeWithSelector(Venta.OpensTooSoon.selector, uint48(0), createdAt + DELAY));
        venta.createDrop(0, 0, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        vm.stopPrank();
    }

    function test_RevertWhen_DatesDoNotMatchTheSnapshot() public {
        uint48 start = uint48(createdAt + DELAY);

        vm.startPrank(operator);
        // No snapshot: both dates must be the same.
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidDates.selector, start, start + 1));
        venta.createDrop(start, start + 1, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidDates.selector, start, start - 1));
        venta.createDrop(start, start - 1, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        // With a snapshot: the public date must come later.
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidDates.selector, start, start));
        venta.createDrop(start, start, _root(), _terms(), _items(TOKEN, 1, PRICE));
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidDates.selector, start, start - 1));
        venta.createDrop(start, start - 1, _root(), _terms(), _items(TOKEN, 1, PRICE));
        vm.stopPrank();
    }

    function test_RevertWhen_StorageTermsMakeNoSense() public {
        uint48 start = uint48(createdAt + DELAY);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidStorageTerms.selector, uint80(0), MAX_FEE));
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: 0, maxFee: MAX_FEE}),
            _items(TOKEN, 1, PRICE)
        );
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidStorageTerms.selector, FEE, uint80(0)));
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: 0}),
            _items(TOKEN, 1, PRICE)
        );
        vm.expectRevert(abi.encodeWithSelector(Venta.InvalidStorageTerms.selector, FEE, FEE - 1));
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: FEE - 1}),
            _items(TOKEN, 1, PRICE)
        );
        vm.stopPrank();
    }

    function test_RevertWhen_StorageCeilingIsAboveTheMaximum() public {
        uint48 start = uint48(createdAt + DELAY);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.StorageFeeAboveMaximum.selector, MAX_STORAGE + 1, MAX_STORAGE));
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: MAX_STORAGE + 1}),
            _items(TOKEN, 1, PRICE)
        );

        // Exactly the maximum is accepted, and so is a drop with no storage fee at all.
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: FREE_PERIOD, feePerPeriod: FEE, maxFee: MAX_STORAGE}),
            _items(TOKEN, 1, PRICE)
        );
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}),
            _items(TOKEN + 1, 1, PRICE)
        );
        vm.stopPrank();
    }

    function test_RevertWhen_APriceIsBelowTheMinimum() public {
        uint48 start = uint48(createdAt + DELAY);
        Venta.NewItem[] memory items = _items(TOKEN, 3, PRICE);
        items[2].price = MIN_PRICE - 1;

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceBelowMinimum.selector, TOKEN + 2, MIN_PRICE - 1, MIN_PRICE));
        venta.createDrop(start, start, bytes32(0), _terms(), items);

        // Nothing of the failed drop was recorded, and the minimum itself is a valid price.
        assertEq(venta.dropCount(), 0);
        items[2].price = MIN_PRICE;
        venta.createDrop(start, start, bytes32(0), _terms(), items);
        vm.stopPrank();
    }

    function test_RevertWhen_AGarmentHasNoFingerprint() public {
        uint48 start = uint48(createdAt + DELAY);
        Venta.NewItem[] memory items = _items(TOKEN, 2, PRICE);
        items[1].contentHash = bytes32(0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.EmptyContentHash.selector, TOKEN + 1));
        venta.createDrop(start, start, bytes32(0), _terms(), items);
    }

    function test_RevertWhen_ANumberIsRepeatedInTheDrop() public {
        uint48 start = uint48(createdAt + DELAY);
        Venta.NewItem[] memory items = _items(TOKEN, 3, PRICE);
        items[2].tokenId = TOKEN;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.TokenIdNotAvailable.selector, TOKEN));
        venta.createDrop(start, start, bytes32(0), _terms(), items);
    }

    function test_RevertWhen_ANumberIsAlreadyInAnotherDrop() public {
        _createDrop(TOKEN, 2);
        uint48 start = uint48(createdAt + DELAY);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.TokenIdNotAvailable.selector, TOKEN + 1));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN + 1, 1, PRICE));
    }

    function test_RevertWhen_ANumberWasAlreadySold() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _buy(alice, TOKEN);
        uint48 start = uint48(block.timestamp + DELAY);

        // Still refused after the garment was claimed and its NFT burned: a number is sold once.
        vm.prank(alice);
        prenda.claim(TOKEN, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.TokenIdNotAvailable.selector, TOKEN));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
    }

    function test_RevertWhen_ANumberWasUsedByAnotherSaleModule() public {
        OpenMinterMock other = new OpenMinterMock(prenda);
        vm.prank(admin);
        prenda.setMinter(address(other), true);
        other.mint(alice, TOKEN, _terms(), _hashOf(TOKEN));
        uint48 start = uint48(createdAt + DELAY);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.TokenIdNotAvailable.selector, TOKEN));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Cancelling a drop
    // ------------------------------------------------------------------------------------------------------------

    function test_OperatorCancelsADropBeforeItOpens() public {
        uint32 dropId = _createDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY - 1);

        vm.expectEmit(address(venta));
        emit Venta.DropCancelled(dropId);
        vm.prank(operator);
        venta.cancelDrop(dropId);

        assertTrue(venta.dropOf(dropId).cancelled);
    }

    function test_AdminCancelsADropBeforeItOpens() public {
        uint32 dropId = _createDrop(TOKEN, 2);

        vm.prank(admin);
        venta.cancelDrop(dropId);

        assertTrue(venta.dropOf(dropId).cancelled);
    }

    function test_RevertWhen_BuyingFromACancelledDrop() public {
        uint32 dropId = _createDrop(TOKEN, 1);
        vm.prank(operator);
        venta.cancelDrop(dropId);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN));
        venta.buy(TOKEN, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), PRICE);
    }

    function test_GarmentsOfACancelledDropCanGoIntoANewOne() public {
        uint32 cancelled = _createDrop(TOKEN, 2);
        vm.prank(operator);
        venta.cancelDrop(cancelled);

        // Same numbers, new price, new drop.
        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        uint32 dropId = venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 2, 2 * PRICE));

        (uint32 itemDrop, uint80 price, , ) = venta.itemOf(TOKEN);
        assertEq(itemDrop, dropId);
        assertEq(price, 2 * PRICE);

        vm.warp(start);
        _fundAndApprove(alice, 2 * PRICE);
        vm.prank(alice);
        venta.buy(TOKEN, 2 * PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_SomeoneElseCancelsADrop() public {
        uint32 dropId = _createDrop(TOKEN, 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperatorOrAdmin.selector, stranger));
        venta.cancelDrop(dropId);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperatorOrAdmin.selector, treasury));
        venta.cancelDrop(dropId);
    }

    function test_RevertWhen_CancellingADropThatAlreadyOpened() public {
        uint32 dropId = _createDrop(TOKEN, 1);
        uint32 earlyDropId = _createEarlyDrop(TOKEN + 1, 1);
        vm.warp(createdAt + DELAY);

        // A drop is open from the first moment somebody can buy, early window included.
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropAlreadyOpen.selector, dropId));
        venta.cancelDrop(dropId);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropAlreadyOpen.selector, earlyDropId));
        venta.cancelDrop(earlyDropId);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropAlreadyOpen.selector, dropId));
        venta.cancelDrop(dropId);
    }

    function test_RevertWhen_CancellingTwiceOrADropThatDoesNotExist() public {
        uint32 dropId = _createDrop(TOKEN, 1);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.UnknownDrop.selector, uint32(0)));
        venta.cancelDrop(0);
        vm.expectRevert(abi.encodeWithSelector(Venta.UnknownDrop.selector, dropId + 1));
        venta.cancelDrop(dropId + 1);

        venta.cancelDrop(dropId);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropAlreadyCancelled.selector, dropId));
        venta.cancelDrop(dropId);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Buying
    // ------------------------------------------------------------------------------------------------------------

    function test_BuySendsThePriceToTheTreasuryAndTheNftToTheBuyer() public {
        uint32 dropId = _createDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.expectEmit(address(venta));
        emit Venta.Purchased(dropId, TOKEN, alice, PRICE, false);
        vm.expectEmit(address(prenda));
        emit Prenda.Minted(
            TOKEN,
            alice,
            address(venta),
            uint48(block.timestamp + FREE_PERIOD),
            FEE,
            MAX_FEE,
            _hashOf(TOKEN)
        );
        vm.prank(alice);
        venta.buy(TOKEN, PRICE, _noProof());

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(usdt.balanceOf(treasury), PRICE);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(address(venta)), 0);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(usdt.allowance(alice, address(venta)), 0);
        (, , bool sold, ) = venta.itemOf(TOKEN);
        assertTrue(sold);
        (, , bool otherSold, ) = venta.itemOf(TOKEN + 1);
        assertFalse(otherSold);
    }

    function test_BuyGivesTheNftTheStorageTermsAndFingerprintOfItsDrop() public {
        _createDrop(TOKEN, 1);
        // Bought ten days after the drop opened: free storage is counted from the purchase.
        vm.warp(createdAt + DELAY + 10 days);
        _buy(alice, TOKEN);

        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, block.timestamp + FREE_PERIOD);
        assertEq(feePerPeriod, FEE);
        assertEq(maxFee, MAX_FEE);
        assertEq(prenda.contentHashOf(TOKEN), _hashOf(TOKEN));
    }

    function test_BuyTakesOnlyThePriceWhenMoreWasApproved() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 3 * uint256(PRICE));

        vm.prank(alice);
        venta.buy(TOKEN, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), 2 * uint256(PRICE));
        assertEq(usdt.balanceOf(treasury), PRICE);
    }

    function test_BuyPaysTheTreasuryInForceAtThatMoment() public {
        address newTreasury = makeAddr("new treasury");
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        vm.prank(admin);
        prenda.setTreasury(newTreasury);

        _buy(alice, TOKEN);

        assertEq(usdt.balanceOf(newTreasury), PRICE);
        assertEq(usdt.balanceOf(treasury), 0);
    }

    function test_EachGarmentIsPaidAtItsOwnPrice() public {
        uint48 start = uint48(createdAt + DELAY);
        Venta.NewItem[] memory items = _items(TOKEN, 2, PRICE);
        items[1].price = 3 * PRICE;
        vm.prank(operator);
        venta.createDrop(start, start, bytes32(0), _terms(), items);
        vm.warp(start);
        _fundAndApprove(alice, 4 * uint256(PRICE));

        vm.startPrank(alice);
        venta.buy(TOKEN, PRICE, _noProof());
        venta.buy(TOKEN + 1, 3 * uint256(PRICE), _noProof());
        vm.stopPrank();

        assertEq(usdt.balanceOf(treasury), 4 * uint256(PRICE));
        assertEq(prenda.balanceOf(alice), 2);
    }

    function test_AContractCanBuy() public {
        ReentrantSaleBuyerMock buyer = new ReentrantSaleBuyerMock(venta);
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        vm.prank(alice);
        usdt.mint(PRICE);
        vm.prank(alice);
        usdt.transfer(address(buyer), PRICE);

        buyer.buy(usdt, TOKEN, PRICE, _noProof(), 0, 0);

        assertEq(prenda.ownerOf(TOKEN), address(buyer));
        assertEq(usdt.balanceOf(treasury), PRICE);
    }

    function test_RevertWhen_BuyingBeforeTheDropOpens() public {
        _createDrop(TOKEN, 1);
        _fundAndApprove(alice, PRICE);
        vm.warp(createdAt + DELAY - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOpenYet.selector, TOKEN, uint48(createdAt + DELAY)));
        venta.buy(TOKEN, PRICE, _noProof());
    }

    function test_RevertWhen_BuyingAGarmentThatIsNotOnSale() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN + 1));
        venta.buy(TOKEN + 1, PRICE, _noProof());
    }

    function test_RevertWhen_BuyingAGarmentAlreadySold() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _buy(alice, TOKEN);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.AlreadySold.selector, TOKEN));
        venta.buy(TOKEN, PRICE, _noProof());

        // Not even after its NFT was claimed and burned.
        vm.prank(alice);
        prenda.claim(TOKEN, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.AlreadySold.selector, TOKEN));
        venta.buy(TOKEN, PRICE, _noProof());

        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(usdt.balanceOf(treasury), PRICE);
    }

    function test_RevertWhen_ThePriceIsNotTheOneTheBuyerExpected() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 2 * uint256(PRICE));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, uint256(PRICE) - 1));
        venta.buy(TOKEN, uint256(PRICE) - 1, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, uint256(PRICE) + 1));
        venta.buy(TOKEN, uint256(PRICE) + 1, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, uint256(0)));
        venta.buy(TOKEN, 0, _noProof());
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), 2 * uint256(PRICE));
    }

    function test_RevertWhen_TheBuyerDidNotApproveThePrice() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, uint256(PRICE) - 1);
        vm.prank(alice);
        usdt.mint(1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(venta),
                uint256(PRICE) - 1,
                uint256(PRICE)
            )
        );
        venta.buy(TOKEN, PRICE, _noProof());

        // Nothing happened: the garment is still on sale and somebody else can buy it.
        (, , bool sold, ) = venta.itemOf(TOKEN);
        assertFalse(sold);
        assertFalse(prenda.isTokenIdUsed(TOKEN));
        _buy(bob, TOKEN);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function test_RevertWhen_TheBuyerCannotPay() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        vm.prank(alice);
        usdt.approve(address(venta), PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, PRICE));
        venta.buy(TOKEN, PRICE, _noProof());

        (, , bool sold, ) = venta.itemOf(TOKEN);
        assertFalse(sold);
    }

    function test_RevertWhen_BuyingWhileSalesArePaused() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);
        vm.prank(admin);
        prenda.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        venta.buy(TOKEN, PRICE, _noProof());

        // She was not charged, and the sale resumes when the pause ends.
        assertEq(usdt.balanceOf(alice), PRICE);
        assertEq(usdt.balanceOf(treasury), 0);
        vm.prank(admin);
        prenda.unpause();
        vm.prank(alice);
        venta.buy(TOKEN, PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev The pause stops purchases. Loading a drop, and above all cancelling one, keep working.
    function test_DropsCanBeCreatedAndCancelledWhileSalesArePaused() public {
        vm.prank(admin);
        prenda.pause();

        uint32 dropId = _createDrop(TOKEN, 1);
        uint32 other = _createEarlyDrop(TOKEN + 1, 1);
        vm.prank(operator);
        venta.cancelDrop(dropId);
        vm.prank(admin);
        venta.cancelDrop(other);
        vm.prank(admin);
        venta.setOperator(stranger);

        assertTrue(venta.dropOf(dropId).cancelled);
        assertTrue(venta.dropOf(other).cancelled);
        assertEq(venta.operator(), stranger);
    }

    function test_RevertWhen_TheModuleWasRetired() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);
        vm.prank(admin);
        prenda.setMinter(address(venta), false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.NotMinter.selector, address(venta)));
        venta.buy(TOKEN, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), PRICE);
        assertEq(usdt.balanceOf(treasury), 0);
    }

    function test_RevertWhen_AnotherModuleUsedTheNumberAfterTheDropWasCreated() public {
        _createDrop(TOKEN, 1);
        OpenMinterMock other = new OpenMinterMock(prenda);
        vm.prank(admin);
        prenda.setMinter(address(other), true);
        other.mint(bob, TOKEN, _terms(), _hashOf(TOKEN));
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Prenda.TokenIdAlreadyUsed.selector, TOKEN));
        venta.buy(TOKEN, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), PRICE);
        assertEq(usdt.balanceOf(treasury), 0);
        assertEq(prenda.ownerOf(TOKEN), bob);
    }

    function testFuzz_BuyMovesExactlyThePriceAndNothingStaysInTheContracts(
        uint80 price,
        uint32 freePeriod,
        uint40 wait
    ) public {
        price = uint80(bound(price, MIN_PRICE, 10_000 * 10 ** 6));
        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: freePeriod, feePerPeriod: FEE, maxFee: MAX_FEE}),
            _items(TOKEN, 1, price)
        );
        vm.warp(uint256(start) + wait);
        _fundAndApprove(alice, price);

        vm.prank(alice);
        venta.buy(TOKEN, price, _noProof());

        assertEq(usdt.balanceOf(treasury), price);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(usdt.balanceOf(address(venta)), 0);
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(prenda.ownerOf(TOKEN), alice);
        (uint48 freeUntil, , ) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, uint256(start) + wait + freePeriod);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The early window
    // ------------------------------------------------------------------------------------------------------------

    function test_WalletInTheSnapshotBuysDuringTheEarlyWindow() public {
        uint32 dropId = _createEarlyDrop(TOKEN, 3);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);
        _fundAndApprove(carol, PRICE);

        vm.expectEmit(address(venta));
        emit Venta.Purchased(dropId, TOKEN, alice, PRICE, true);
        vm.prank(alice);
        venta.buy(TOKEN, PRICE, _proofOf(alice));

        // Until the last second of the window.
        vm.warp(createdAt + DELAY + EARLY_WINDOW - 1);
        vm.prank(carol);
        venta.buy(TOKEN + 1, PRICE, _proofOf(carol));

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.ownerOf(TOKEN + 1), carol);
        assertTrue(venta.boughtEarly(dropId, alice));
        assertTrue(venta.boughtEarly(dropId, carol));
        assertFalse(venta.boughtEarly(dropId, bob));
        assertEq(usdt.balanceOf(treasury), 2 * uint256(PRICE));
    }

    function test_RevertWhen_BuyingBeforeTheEarlyWindow() public {
        _createEarlyDrop(TOKEN, 1);
        _fundAndApprove(alice, PRICE);
        vm.warp(createdAt + DELAY - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOpenYet.selector, TOKEN, uint48(createdAt + DELAY)));
        venta.buy(TOKEN, PRICE, _proofOf(alice));
    }

    function test_RevertWhen_WalletOutsideTheSnapshotBuysDuringTheEarlyWindow() public {
        _createEarlyDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(stranger, PRICE);

        vm.startPrank(stranger);
        // With no proof, with somebody else's proof, with a made-up proof.
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, PRICE, _proofOf(alice));
        bytes32[] memory madeUp = new bytes32[](2);
        madeUp[0] = _leaf(stranger);
        madeUp[1] = _root();
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, PRICE, madeUp);
        vm.stopPrank();

        assertEq(usdt.balanceOf(stranger), PRICE);
        assertFalse(prenda.isTokenIdUsed(TOKEN));
    }

    function test_RevertWhen_WalletInTheSnapshotUsesAWrongProof() public {
        _createEarlyDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, alice));
        venta.buy(TOKEN, PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, alice));
        venta.buy(TOKEN, PRICE, _proofOf(carol));
        vm.stopPrank();
    }

    function test_RevertWhen_WalletBuysASecondGarmentDuringTheEarlyWindow() public {
        _createEarlyDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 2 * uint256(PRICE));
        bytes32[] memory proof = _proofOf(alice);

        vm.startPrank(alice);
        venta.buy(TOKEN, PRICE, proof);
        vm.expectRevert(abi.encodeWithSelector(Venta.EarlyPurchaseAlreadyMade.selector, alice));
        venta.buy(TOKEN + 1, PRICE, proof);
        vm.stopPrank();

        assertEq(prenda.balanceOf(alice), 1);
        assertEq(usdt.balanceOf(alice), PRICE);
    }

    function test_AFailedEarlyPurchaseDoesNotUseUpTheTurn() public {
        uint32 dropId = _createEarlyDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        bytes32[] memory proof = _proofOf(alice);

        // She has no money yet: the purchase fails and her turn is still there.
        vm.prank(alice);
        usdt.approve(address(venta), PRICE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, PRICE));
        venta.buy(TOKEN, PRICE, proof);
        assertFalse(venta.boughtEarly(dropId, alice));

        vm.prank(alice);
        usdt.mint(PRICE);
        vm.prank(alice);
        venta.buy(TOKEN, PRICE, proof);
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_AfterTheEarlyWindowAnyoneBuysAndThereIsNoLimit() public {
        uint32 dropId = _createEarlyDrop(TOKEN, 4);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 3 * uint256(PRICE));
        vm.prank(alice);
        venta.buy(TOKEN, PRICE, _proofOf(alice));

        vm.warp(createdAt + DELAY + EARLY_WINDOW);
        _fundAndApprove(stranger, PRICE);

        // Somebody outside the snapshot, with no proof.
        vm.expectEmit(address(venta));
        emit Venta.Purchased(dropId, TOKEN + 1, stranger, PRICE, false);
        vm.prank(stranger);
        venta.buy(TOKEN + 1, PRICE, _noProof());
        // And alice again, twice, whatever she passes as proof.
        vm.startPrank(alice);
        venta.buy(TOKEN + 2, PRICE, _noProof());
        venta.buy(TOKEN + 3, PRICE, _proofOf(carol));
        vm.stopPrank();

        assertEq(prenda.balanceOf(alice), 3);
        assertEq(prenda.ownerOf(TOKEN + 1), stranger);
        assertFalse(venta.boughtEarly(dropId, stranger));
    }

    function test_TheEarlyTurnIsCountedPerDrop() public {
        uint32 first = _createEarlyDrop(TOKEN, 1);
        uint32 second = _createEarlyDrop(TOKEN + 1, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 2 * uint256(PRICE));
        bytes32[] memory proof = _proofOf(alice);

        vm.startPrank(alice);
        venta.buy(TOKEN, PRICE, proof);
        venta.buy(TOKEN + 1, PRICE, proof);
        vm.stopPrank();

        assertTrue(venta.boughtEarly(first, alice));
        assertTrue(venta.boughtEarly(second, alice));
        assertEq(prenda.balanceOf(alice), 2);
    }

    // ------------------------------------------------------------------------------------------------------------
    // A payment token that calls the buyer back, and one whose issuer blocks accounts
    // (models of what USDT0's issuer could do, not the real USDT0)
    // ------------------------------------------------------------------------------------------------------------

    function _callbackSetup(
        bool withEarlyWindow
    ) internal returns (CallbackTokenMock token, Venta other, Prenda otherPrenda, ReentrantSaleBuyerMock buyer) {
        token = new CallbackTokenMock();
        (otherPrenda, other) = _deployWith(token);
        buyer = new ReentrantSaleBuyerMock(other);
        token.mint(address(buyer), 2 * uint256(PRICE));

        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        if (withEarlyWindow) {
            // A snapshot with two wallets: the cheating buyer and alice.
            bytes32 root = Hashes.commutativeKeccak256(_leaf(address(buyer)), _leaf(alice));
            other.createDrop(start, start + EARLY_WINDOW, root, _terms(), _items(TOKEN, 2, PRICE));
        } else {
            other.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 2, PRICE));
        }
        vm.warp(start);
    }

    function test_BuyerCannotBuyTheSameGarmentTwiceFromInsideThePayment() public {
        (CallbackTokenMock token, , Prenda otherPrenda, ReentrantSaleBuyerMock buyer) = _callbackSetup(false);

        buyer.buy(token, TOKEN, PRICE, _noProof(), TOKEN, PRICE);

        assertTrue(buyer.callbackRan());
        assertFalse(buyer.secondPurchaseWorked());
        assertEq(otherPrenda.ownerOf(TOKEN), address(buyer));
        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(token.balanceOf(address(buyer)), PRICE);
    }

    function test_BuyerCannotTakeTwoEarlyTurnsFromInsideThePayment() public {
        (CallbackTokenMock token, , Prenda otherPrenda, ReentrantSaleBuyerMock buyer) = _callbackSetup(true);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(alice);

        buyer.buy(token, TOKEN, PRICE, proof, TOKEN + 1, PRICE);

        assertTrue(buyer.callbackRan());
        assertFalse(buyer.secondPurchaseWorked());
        assertEq(otherPrenda.balanceOf(address(buyer)), 1);
        assertFalse(otherPrenda.isTokenIdUsed(TOKEN + 1));
        assertEq(token.balanceOf(treasury), PRICE);
    }

    function _blocklistSetup() internal returns (BlocklistTokenMock token, Venta other, Prenda otherPrenda) {
        token = new BlocklistTokenMock();
        (otherPrenda, other) = _deployWith(token);
        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        other.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        vm.warp(start);
        token.mint(alice, PRICE);
        vm.prank(alice);
        token.approve(address(other), PRICE);
    }

    function test_BuyReachesATreasuryThatTheIssuerBlocked() public {
        (BlocklistTokenMock token, Venta other, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(treasury, true);

        vm.prank(alice);
        other.buy(TOKEN, PRICE, _noProof());

        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(otherPrenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_TheIssuerBlockedTheBuyer() public {
        (BlocklistTokenMock token, Venta other, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, alice));
        other.buy(TOKEN, PRICE, _noProof());

        assertFalse(otherPrenda.isTokenIdUsed(TOKEN));
    }

    /// @dev A known limit: if the issuer blocks this module, its sales stop. The way out is a new sale module.
    function test_RevertWhen_TheIssuerBlockedTheSaleContract() public {
        (BlocklistTokenMock token, Venta other, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(address(other), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, address(other)));
        other.buy(TOKEN, PRICE, _noProof());

        assertFalse(otherPrenda.isTokenIdUsed(TOKEN));
        assertEq(token.balanceOf(alice), PRICE);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------------------------------------------------

    function test_AdminNamesANewOperator() public {
        address newOperator = makeAddr("new operator");

        vm.expectEmit(address(venta));
        emit Venta.OperatorChanged(operator, newOperator);
        vm.prank(admin);
        venta.setOperator(newOperator);

        assertEq(venta.operator(), newOperator);
        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperator.selector, operator));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        vm.prank(newOperator);
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
    }

    function test_AdminCanLeaveTheRoleOfOperatorEmpty() public {
        vm.prank(admin);
        venta.setOperator(address(0));

        assertEq(venta.operator(), address(0));
        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperator.selector, operator));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
    }

    function test_RevertWhen_SomeoneElseNamesTheOperator() public {
        address[3] memory callers = [stranger, operator, treasury];

        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Venta.NotAdmin.selector, callers[i]));
            venta.setOperator(callers[i]);
        }
        assertEq(venta.operator(), operator);
    }

    /// @dev This contract has no administration of its own: it follows the one of the NFT contract.
    function test_AdministrationFollowsTheNftContract() public {
        address newAdmin = makeAddr("new admin");
        uint32 dropId = _createDrop(TOKEN, 1);
        vm.prank(admin);
        prenda.transferOwnership(newAdmin);
        vm.prank(newAdmin);
        prenda.acceptOwnership();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotAdmin.selector, admin));
        venta.setOperator(admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperatorOrAdmin.selector, admin));
        venta.cancelDrop(dropId);

        vm.startPrank(newAdmin);
        venta.setOperator(newAdmin);
        venta.cancelDrop(dropId);
        vm.stopPrank();
        assertEq(venta.operator(), newAdmin);
    }
}
