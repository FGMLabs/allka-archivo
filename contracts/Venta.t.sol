// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Prenda} from "./Prenda.sol";
import {Venta} from "./Venta.sol";
import {ReentrantSaleBuyerMock} from "./mocks/BuyerMocks.sol";
import {OpenMinterMock} from "./mocks/OpenMinterMock.sol";
import {BlocklistTokenMock, CallbackTokenMock, FalseReturningTokenMock} from "./mocks/PaymentTokenMocks.sol";
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
    /// @dev Id of the first drop of a sale module. Most tests create only that one.
    uint32 internal constant DROP = 1;
    bytes32 internal constant ORDER = keccak256("order 1");

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
        venta.buy(tokenId, DROP, PRICE, _noProof());
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

    function test_DeploymentAnnouncesTheOperator() public {
        vm.expectEmit();
        emit Venta.OperatorChanged(address(0), operator);
        new Venta(prenda, operator, DELAY, MIN_PRICE, MAX_STORAGE);
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
        assertFalse(drop.closed);

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
        prenda.claim(TOKEN, 0, ORDER);
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
    // Closing a drop
    // ------------------------------------------------------------------------------------------------------------

    function test_OperatorClosesADropBeforeItOpens() public {
        uint32 dropId = _createDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY - 1);

        vm.expectEmit(address(venta));
        emit Venta.DropClosed(dropId);
        vm.prank(operator);
        venta.closeDrop(dropId);

        assertTrue(venta.dropOf(dropId).closed);
    }

    function test_AdminClosesADropBeforeItOpens() public {
        uint32 dropId = _createDrop(TOKEN, 2);

        vm.prank(admin);
        venta.closeDrop(dropId);

        assertTrue(venta.dropOf(dropId).closed);
    }

    function test_RevertWhen_BuyingFromADropClosedBeforeItOpened() public {
        uint32 dropId = _createDrop(TOKEN, 1);
        vm.prank(operator);
        venta.closeDrop(dropId);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN));
        venta.buy(TOKEN, dropId, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), PRICE);
    }

    /// @dev Closing a drop that already sold something: what was sold stays sold, the rest stops being on sale.
    function test_OperatorClosesAnOpenDrop() public {
        uint32 dropId = _createDrop(TOKEN, 3);
        vm.warp(createdAt + DELAY);
        _buy(alice, TOKEN);
        _fundAndApprove(bob, PRICE);

        vm.expectEmit(address(venta));
        emit Venta.DropClosed(dropId);
        vm.prank(operator);
        venta.closeDrop(dropId);

        assertTrue(venta.dropOf(dropId).closed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN + 1));
        venta.buy(TOKEN + 1, dropId, PRICE, _noProof());
        assertEq(usdt.balanceOf(bob), PRICE);
        assertFalse(prenda.isTokenIdUsed(TOKEN + 1));

        // Alice keeps her NFT, with the storage rules of the drop, and the money stays where it went.
        assertEq(prenda.ownerOf(TOKEN), alice);
        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, block.timestamp + FREE_PERIOD);
        assertEq(feePerPeriod, FEE);
        assertEq(maxFee, MAX_FEE);
        assertEq(usdt.balanceOf(treasury), PRICE);
        (uint32 itemDrop, , bool sold, ) = venta.itemOf(TOKEN);
        assertEq(itemDrop, dropId);
        assertTrue(sold);
        vm.prank(alice);
        prenda.claim(TOKEN, 0, ORDER);
    }

    function test_AdminClosesADropDuringItsEarlyWindow() public {
        uint32 dropId = _createEarlyDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);
        vm.prank(alice);
        venta.buy(TOKEN, dropId, PRICE, _proofOf(alice));

        vm.prank(admin);
        venta.closeDrop(dropId);

        _fundAndApprove(bob, PRICE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN + 1));
        venta.buy(TOKEN + 1, dropId, PRICE, _proofOf(bob));
        // Not after the window either.
        vm.warp(createdAt + DELAY + EARLY_WINDOW);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN + 1));
        venta.buy(TOKEN + 1, dropId, PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_GarmentsOfAClosedDropCanGoIntoANewOne() public {
        uint32 closed = _createDrop(TOKEN, 2);
        vm.prank(operator);
        venta.closeDrop(closed);

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
        venta.buy(TOKEN, dropId, 2 * PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev After an open drop is closed, what it did not sell can be sold again; what it sold, never.
    function test_OnlyTheUnsoldGarmentsOfAnOpenDropThatWasClosedCanGoIntoANewOne() public {
        uint32 closed = _createDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY);
        _buy(alice, TOKEN);
        vm.startPrank(operator);
        venta.closeDrop(closed);

        uint48 start = uint48(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(Venta.TokenIdNotAvailable.selector, TOKEN));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 2, PRICE));
        uint32 dropId = venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN + 1, 1, 2 * PRICE));
        vm.stopPrank();

        // The new drop waits like any other.
        _fundAndApprove(bob, 2 * PRICE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOpenYet.selector, TOKEN + 1, start));
        venta.buy(TOKEN + 1, dropId, 2 * PRICE, _noProof());
        vm.warp(start);
        vm.prank(bob);
        venta.buy(TOKEN + 1, dropId, 2 * PRICE, _noProof());

        assertEq(prenda.ownerOf(TOKEN), alice);
        assertEq(prenda.ownerOf(TOKEN + 1), bob);
        assertEq(usdt.balanceOf(treasury), 3 * uint256(PRICE));
    }

    /// @dev A garment that goes from a closed drop into a new one takes everything from the new one: price,
    /// storage rules, fingerprint, and a fresh early window.
    function test_RelistedGarmentTakesEverythingFromItsNewDrop() public {
        uint32 first = _createEarlyDrop(TOKEN, 1);
        uint48 start = uint48(createdAt + DELAY);
        Venta.NewItem[] memory items = new Venta.NewItem[](1);
        items[0] = Venta.NewItem({tokenId: TOKEN, price: 2 * PRICE, contentHash: keccak256("corrected data")});
        vm.startPrank(operator);
        venta.closeDrop(first);
        uint32 second = venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}),
            items
        );
        vm.stopPrank();

        (uint32 itemDrop, uint80 price, bool sold, bytes32 contentHash) = venta.itemOf(TOKEN);
        assertEq(itemDrop, second);
        assertEq(price, 2 * PRICE);
        assertFalse(sold);
        assertEq(contentHash, keccak256("corrected data"));

        // The new drop has no early window: somebody outside the snapshot of the first one buys with no proof.
        vm.warp(start);
        _fundAndApprove(stranger, 2 * PRICE);
        vm.prank(stranger);
        venta.buy(TOKEN, second, 2 * PRICE, _noProof());

        assertEq(prenda.contentHashOf(TOKEN), keccak256("corrected data"));
        (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(TOKEN);
        assertEq(freeUntil, block.timestamp);
        assertEq(feePerPeriod, 0);
        assertEq(maxFee, 0);
        assertFalse(venta.boughtEarly(first, stranger));
        assertFalse(venta.boughtEarly(second, stranger));
    }

    function test_ClosingADropLeavesTheOtherDropsAlone() public {
        uint32 closed = _createDrop(TOKEN, 1);
        uint32 open = _createDrop(TOKEN + 1, 1);
        vm.prank(operator);
        venta.closeDrop(closed);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        venta.buy(TOKEN + 1, open, PRICE, _noProof());

        assertFalse(venta.dropOf(open).closed);
        assertEq(prenda.ownerOf(TOKEN + 1), alice);
    }

    function test_RevertWhen_SomeoneElseClosesADrop() public {
        uint32 dropId = _createDrop(TOKEN, 1);
        address[4] memory callers = [stranger, treasury, alice, address(prenda)];

        // Before it opens and after.
        for (uint256 round = 0; round < 2; round++) {
            for (uint256 i = 0; i < callers.length; i++) {
                vm.prank(callers[i]);
                vm.expectRevert(abi.encodeWithSelector(Venta.NotOperatorOrAdmin.selector, callers[i]));
                venta.closeDrop(dropId);
            }
            vm.warp(createdAt + DELAY);
        }
        assertFalse(venta.dropOf(dropId).closed);
    }

    function test_RevertWhen_ClosingTwiceOrADropThatDoesNotExist() public {
        uint32 dropId = _createDrop(TOKEN, 1);
        uint32 openDropId = _createDrop(TOKEN + 1, 1);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.UnknownDrop.selector, uint32(0)));
        venta.closeDrop(0);
        vm.expectRevert(abi.encodeWithSelector(Venta.UnknownDrop.selector, openDropId + 1));
        venta.closeDrop(openDropId + 1);

        venta.closeDrop(dropId);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropAlreadyClosed.selector, dropId));
        venta.closeDrop(dropId);

        // The latest drop can be closed, and an open drop is closed only once too.
        vm.warp(createdAt + DELAY);
        venta.closeDrop(openDropId);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropAlreadyClosed.selector, openDropId));
        venta.closeDrop(openDropId);
        vm.stopPrank();
    }

    /// @dev A public date typed wrong (here, in milliseconds) leaves a drop that only the snapshot can ever buy
    /// from. Closing it and creating it again puts it right.
    function test_ADropWithAMistypedPublicDateCanBeClosedAndCreatedAgain() public {
        vm.warp(1_795_000_000);
        uint48 earlyStart = uint48(block.timestamp + DELAY);
        uint48 publicStartInMilliseconds = uint48((block.timestamp + DELAY + EARLY_WINDOW) * 1000);
        vm.prank(operator);
        uint32 wrong = venta.createDrop(earlyStart, publicStartInMilliseconds, _root(), _terms(), _items(TOKEN, 1, PRICE));

        vm.warp(uint256(earlyStart) + 3650 days);
        _fundAndApprove(stranger, PRICE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, wrong, PRICE, _noProof());

        uint48 start = uint48(block.timestamp + DELAY);
        vm.startPrank(operator);
        venta.closeDrop(wrong);
        uint32 right = venta.createDrop(start, start + EARLY_WINDOW, _root(), _terms(), _items(TOKEN, 1, PRICE));
        vm.stopPrank();
        vm.warp(start + EARLY_WINDOW);
        vm.prank(stranger);
        venta.buy(TOKEN, right, PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN), stranger);
    }

    /**
     * @dev The operator key is stolen. The thief loads real garments at the lowest price, with an early window for
     * its own wallets that never ends, and nobody notices before the drop opens. The administration can still
     * close the drop and name a new operator: what the thief had not bought yet is safe and can be sold again in
     * this same module.
     */
    function test_AdminStopsADropLoadedWithAStolenOperatorKey() public {
        address thief = makeAddr("thief");
        address secondWallet = makeAddr("second wallet of the thief");
        uint48 earlyStart = uint48(createdAt + DELAY);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(secondWallet);
        vm.prank(operator);
        uint32 dropId = venta.createDrop(
            earlyStart,
            type(uint48).max,
            Hashes.commutativeKeccak256(_leaf(thief), _leaf(secondWallet)),
            Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}),
            _items(TOKEN, 3, MIN_PRICE)
        );
        vm.warp(earlyStart);
        vm.startPrank(thief);
        usdt.mint(MIN_PRICE);
        usdt.approve(address(venta), MIN_PRICE);
        venta.buy(TOKEN, dropId, MIN_PRICE, proof);
        vm.stopPrank();

        address newOperator = makeAddr("new operator");
        vm.startPrank(admin);
        venta.closeDrop(dropId);
        venta.setOperator(newOperator);
        vm.stopPrank();

        // The second wallet of the thief is too late, and the stolen key creates nothing any more.
        proof[0] = _leaf(thief);
        vm.startPrank(secondWallet);
        usdt.mint(MIN_PRICE);
        usdt.approve(address(venta), MIN_PRICE);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN + 1));
        venta.buy(TOKEN + 1, dropId, MIN_PRICE, proof);
        vm.stopPrank();
        uint48 start = uint48(block.timestamp + DELAY);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperator.selector, operator));
        venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN + 1, 2, PRICE));

        // The two garments that were left go on sale again at their real price.
        vm.prank(newOperator);
        uint32 honest = venta.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN + 1, 2, PRICE));
        vm.warp(start);
        _fundAndApprove(alice, PRICE);
        vm.prank(alice);
        venta.buy(TOKEN + 1, honest, PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN + 1), alice);
        assertEq(prenda.ownerOf(TOKEN), thief);
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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), 2 * uint256(PRICE));
        assertEq(usdt.balanceOf(treasury), PRICE);
    }

    function test_BuyPaysTheTreasuryInForceAtThatMoment() public {
        address newTreasury = makeAddr("new treasury");
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        vm.prank(admin);
        prenda.proposeTreasury(newTreasury);
        vm.prank(newTreasury);
        prenda.acceptTreasury();

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
        venta.buy(TOKEN, DROP, PRICE, _noProof());
        venta.buy(TOKEN + 1, DROP, 3 * uint256(PRICE), _noProof());
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

        buyer.buy(usdt, TOKEN, DROP, PRICE, _noProof(), 0, 0);

        assertEq(prenda.ownerOf(TOKEN), address(buyer));
        assertEq(usdt.balanceOf(treasury), PRICE);
    }

    function test_RevertWhen_BuyingBeforeTheDropOpens() public {
        _createDrop(TOKEN, 1);
        _fundAndApprove(alice, PRICE);
        vm.warp(createdAt + DELAY - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOpenYet.selector, TOKEN, uint48(createdAt + DELAY)));
        venta.buy(TOKEN, DROP, PRICE, _noProof());
    }

    function test_RevertWhen_BuyingAGarmentThatIsNotOnSale() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOnSale.selector, TOKEN + 1));
        venta.buy(TOKEN + 1, DROP, PRICE, _noProof());
    }

    function test_RevertWhen_BuyingAGarmentAlreadySold() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _buy(alice, TOKEN);
        _fundAndApprove(bob, PRICE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.AlreadySold.selector, TOKEN));
        venta.buy(TOKEN, DROP, PRICE, _noProof());

        // Not even after its NFT was claimed and burned.
        vm.prank(alice);
        prenda.claim(TOKEN, 0, ORDER);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Venta.AlreadySold.selector, TOKEN));
        venta.buy(TOKEN, DROP, PRICE, _noProof());

        assertEq(usdt.balanceOf(bob), PRICE);
        assertEq(usdt.balanceOf(treasury), PRICE);
    }

    function test_RevertWhen_ThePriceIsNotTheOneTheBuyerExpected() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 2 * uint256(PRICE));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, uint256(PRICE) - 1));
        venta.buy(TOKEN, DROP, uint256(PRICE) - 1, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, uint256(PRICE) + 1));
        venta.buy(TOKEN, DROP, uint256(PRICE) + 1, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, uint256(0)));
        venta.buy(TOKEN, DROP, 0, _noProof());
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), 2 * uint256(PRICE));
    }

    /// @dev The stated price is compared in full, not after cutting it to the size of the stored price.
    function test_RevertWhen_TheStatedPriceOnlyMatchesInItsLowerBits() public {
        _createDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);
        uint256 lookalike = uint256(PRICE) + (uint256(1) << 80);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.PriceNotAsExpected.selector, TOKEN, PRICE, lookalike));
        venta.buy(TOKEN, DROP, lookalike, _noProof());
    }

    function test_RevertWhen_TheBuyerNamesAnotherDrop() public {
        uint32 dropId = _createDrop(TOKEN, 1);
        uint32 other = _createDrop(TOKEN + 1, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, PRICE);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropNotAsExpected.selector, TOKEN, dropId, other));
        venta.buy(TOKEN, other, PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.DropNotAsExpected.selector, TOKEN, dropId, uint32(0)));
        venta.buy(TOKEN, 0, PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.DropNotAsExpected.selector, TOKEN, dropId, other + 1));
        venta.buy(TOKEN, other + 1, PRICE, _noProof());
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), PRICE);
        assertFalse(prenda.isTokenIdUsed(TOKEN));
    }

    /// @dev The purchase a buyer prepared for one drop does not go through against a later drop that offers the
    /// same garment at the same price with the worst storage rules the module allows and with other data.
    function test_RevertWhen_TheGarmentIsNowInADropWithOtherTerms() public {
        uint32 first = _createDrop(TOKEN, 1);
        uint48 start = uint48(createdAt + DELAY);
        Venta.NewItem[] memory items = new Venta.NewItem[](1);
        items[0] = Venta.NewItem({tokenId: TOKEN, price: PRICE, contentHash: keccak256("another garment")});
        vm.startPrank(operator);
        venta.closeDrop(first);
        uint32 second = venta.createDrop(
            start,
            start,
            bytes32(0),
            Prenda.StorageTerms({freePeriod: 0, feePerPeriod: MAX_STORAGE, maxFee: MAX_STORAGE}),
            items
        );
        vm.stopPrank();
        vm.warp(start);
        _fundAndApprove(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Venta.DropNotAsExpected.selector, TOKEN, second, first));
        venta.buy(TOKEN, first, PRICE, _noProof());

        assertEq(usdt.balanceOf(alice), PRICE);
        assertFalse(prenda.isTokenIdUsed(TOKEN));
    }

    /// @dev A payment token that answers false instead of failing must not give the garment away.
    function test_RevertWhen_ThePaymentTokenAnswersFalse() public {
        FalseReturningTokenMock token = new FalseReturningTokenMock();
        (Prenda otherPrenda, Venta other) = _deployWith(IERC20(address(token)));
        uint48 start = uint48(createdAt + DELAY);
        vm.prank(operator);
        other.createDrop(start, start, bytes32(0), _terms(), _items(TOKEN, 1, PRICE));
        vm.warp(start);

        // Alice has neither the money nor an approval.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        other.buy(TOKEN, DROP, PRICE, _noProof());

        assertFalse(otherPrenda.isTokenIdUsed(TOKEN));
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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

        // She was not charged, and the sale resumes when the pause ends.
        assertEq(usdt.balanceOf(alice), PRICE);
        assertEq(usdt.balanceOf(treasury), 0);
        vm.prank(admin);
        prenda.unpause();
        vm.prank(alice);
        venta.buy(TOKEN, DROP, PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    /// @dev The pause stops purchases. Loading a drop, and above all closing one, keep working.
    function test_DropsCanBeCreatedAndClosedWhileSalesArePaused() public {
        vm.prank(admin);
        prenda.pause();

        uint32 dropId = _createDrop(TOKEN, 1);
        uint32 other = _createEarlyDrop(TOKEN + 1, 1);
        vm.prank(operator);
        venta.closeDrop(dropId);
        vm.warp(createdAt + DELAY);
        vm.prank(admin);
        venta.closeDrop(other);
        vm.prank(admin);
        venta.setOperator(stranger);

        assertTrue(venta.dropOf(dropId).closed);
        assertTrue(venta.dropOf(other).closed);
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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

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
        venta.buy(TOKEN, DROP, PRICE, _noProof());

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
        venta.buy(TOKEN, DROP, price, _noProof());

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
        venta.buy(TOKEN, DROP, PRICE, _proofOf(alice));

        // Until the last second of the window.
        vm.warp(createdAt + DELAY + EARLY_WINDOW - 1);
        vm.prank(carol);
        venta.buy(TOKEN + 1, DROP, PRICE, _proofOf(carol));

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
        venta.buy(TOKEN, DROP, PRICE, _proofOf(alice));
    }

    function test_RevertWhen_WalletOutsideTheSnapshotBuysDuringTheEarlyWindow() public {
        _createEarlyDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(stranger, PRICE);

        vm.startPrank(stranger);
        // With no proof, with somebody else's proof, with a made-up proof.
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, DROP, PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, DROP, PRICE, _proofOf(alice));
        bytes32[] memory madeUp = new bytes32[](2);
        madeUp[0] = _leaf(stranger);
        madeUp[1] = _root();
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, DROP, PRICE, madeUp);
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
        venta.buy(TOKEN, DROP, PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, alice));
        venta.buy(TOKEN, DROP, PRICE, _proofOf(carol));
        vm.stopPrank();
    }

    function test_RevertWhen_WalletBuysASecondGarmentDuringTheEarlyWindow() public {
        _createEarlyDrop(TOKEN, 2);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 2 * uint256(PRICE));
        bytes32[] memory proof = _proofOf(alice);

        vm.startPrank(alice);
        venta.buy(TOKEN, DROP, PRICE, proof);
        vm.expectRevert(abi.encodeWithSelector(Venta.EarlyPurchaseAlreadyMade.selector, alice));
        venta.buy(TOKEN + 1, DROP, PRICE, proof);
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
        venta.buy(TOKEN, DROP, PRICE, proof);
        assertFalse(venta.boughtEarly(dropId, alice));

        vm.prank(alice);
        usdt.mint(PRICE);
        vm.prank(alice);
        venta.buy(TOKEN, DROP, PRICE, proof);
        assertEq(prenda.ownerOf(TOKEN), alice);
    }

    function test_AfterTheEarlyWindowAnyoneBuysAndThereIsNoLimit() public {
        uint32 dropId = _createEarlyDrop(TOKEN, 4);
        vm.warp(createdAt + DELAY);
        _fundAndApprove(alice, 3 * uint256(PRICE));
        vm.prank(alice);
        venta.buy(TOKEN, DROP, PRICE, _proofOf(alice));

        vm.warp(createdAt + DELAY + EARLY_WINDOW);
        _fundAndApprove(stranger, PRICE);

        // Somebody outside the snapshot, with no proof.
        vm.expectEmit(address(venta));
        emit Venta.Purchased(dropId, TOKEN + 1, stranger, PRICE, false);
        vm.prank(stranger);
        venta.buy(TOKEN + 1, DROP, PRICE, _noProof());
        // And alice again, twice, whatever she passes as proof.
        vm.startPrank(alice);
        venta.buy(TOKEN + 2, DROP, PRICE, _noProof());
        venta.buy(TOKEN + 3, DROP, PRICE, _proofOf(carol));
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
        venta.buy(TOKEN, first, PRICE, proof);
        venta.buy(TOKEN + 1, second, PRICE, proof);
        vm.stopPrank();

        assertTrue(venta.boughtEarly(first, alice));
        assertTrue(venta.boughtEarly(second, alice));
        assertEq(prenda.balanceOf(alice), 2);
    }

    /// @dev The shortest early window the contract accepts is one second, and it works.
    function test_AnEarlyWindowOfOneSecondWorks() public {
        uint48 earlyStart = uint48(createdAt + DELAY);
        vm.prank(operator);
        uint32 dropId = venta.createDrop(earlyStart, earlyStart + 1, _root(), _terms(), _items(TOKEN, 2, PRICE));
        vm.warp(earlyStart);
        _fundAndApprove(stranger, PRICE);
        _fundAndApprove(alice, PRICE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotInSnapshot.selector, stranger));
        venta.buy(TOKEN, dropId, PRICE, _noProof());
        vm.prank(alice);
        venta.buy(TOKEN, dropId, PRICE, _proofOf(alice));
        assertTrue(venta.boughtEarly(dropId, alice));

        vm.warp(earlyStart + 1);
        vm.prank(stranger);
        venta.buy(TOKEN + 1, dropId, PRICE, _noProof());
        assertEq(prenda.ownerOf(TOKEN + 1), stranger);
    }

    /// @dev A known limit: the pause does not stop the clock. A pause that covers the early window uses it up.
    function test_APauseDuringTheEarlyWindowUsesItUp() public {
        uint32 dropId = _createEarlyDrop(TOKEN, 1);
        vm.warp(createdAt + DELAY);
        vm.prank(admin);
        prenda.pause();
        vm.warp(createdAt + DELAY + EARLY_WINDOW);
        vm.prank(admin);
        prenda.unpause();
        _fundAndApprove(stranger, PRICE);

        vm.prank(stranger);
        venta.buy(TOKEN, dropId, PRICE, _noProof());

        assertEq(prenda.ownerOf(TOKEN), stranger);
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

        buyer.buy(token, TOKEN, DROP, PRICE, _noProof(), TOKEN, PRICE);

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

        buyer.buy(token, TOKEN, DROP, PRICE, proof, TOKEN + 1, PRICE);

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
        other.buy(TOKEN, DROP, PRICE, _noProof());

        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(otherPrenda.ownerOf(TOKEN), alice);
    }

    function test_RevertWhen_TheIssuerBlockedTheBuyer() public {
        (BlocklistTokenMock token, Venta other, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, alice));
        other.buy(TOKEN, DROP, PRICE, _noProof());

        assertFalse(otherPrenda.isTokenIdUsed(TOKEN));
    }

    /// @dev A known limit: if the issuer blocks this module, its sales stop. The way out is a new sale module.
    function test_RevertWhen_TheIssuerBlockedTheSaleContract() public {
        (BlocklistTokenMock token, Venta other, Prenda otherPrenda) = _blocklistSetup();
        token.setBlocked(address(other), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistTokenMock.Blocked.selector, address(other)));
        other.buy(TOKEN, DROP, PRICE, _noProof());

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
        venta.closeDrop(dropId);

        vm.startPrank(newAdmin);
        venta.setOperator(newAdmin);
        venta.closeDrop(dropId);
        vm.stopPrank();
        assertEq(venta.operator(), newAdmin);
    }

    /// @dev A new administration has no power here until it accepts, and the outgoing one keeps it until then.
    function test_PendingAdministrationHasNoPowerYet() public {
        address newAdmin = makeAddr("new admin");
        uint32 dropId = _createDrop(TOKEN, 1);
        vm.prank(admin);
        prenda.transferOwnership(newAdmin);

        vm.startPrank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotOperatorOrAdmin.selector, newAdmin));
        venta.closeDrop(dropId);
        vm.expectRevert(abi.encodeWithSelector(Venta.NotAdmin.selector, newAdmin));
        venta.setOperator(newAdmin);
        vm.stopPrank();

        vm.prank(admin);
        venta.closeDrop(dropId);
        assertTrue(venta.dropOf(dropId).closed);
    }
}
