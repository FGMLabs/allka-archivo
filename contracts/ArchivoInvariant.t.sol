// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {Mercado} from "./Mercado.sol";
import {Prenda} from "./Prenda.sol";
import {Venta} from "./Venta.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

/**
 * @notice Random sequences over the three contracts together: drops are created and cancelled, garments are bought
 * in the early window and after it, NFTs are offered, bought and re-offered on the market, garments are claimed,
 * and in between the clock moves, sales are paused and the treasury changes.
 *
 * Before every operation the handler works out, from its own books, whether the operation should succeed. A result
 * that does not match is written down as a violation. The books also follow every unit of money: what each wallet
 * must hold and what the treasury must have received.
 */
contract ArchivoHandler is Test {
    uint48 public constant DELAY = 1 hours;
    uint48 public constant EARLY_WINDOW = 6 hours;
    uint80 public constant MIN_PRICE = 10 * 10 ** 6;
    uint80 public constant MAX_PRICE = 500 * 10 ** 6;
    uint80 public constant MAX_STORAGE = 100 * 10 ** 6;
    uint48 public constant MAX_LISTING = 30 days;

    struct DropBook {
        uint48 earlyStart;
        uint48 publicStart;
        bool hasEarlyWindow;
        bool cancelled;
        uint32 freePeriod;
        uint80 feePerPeriod;
        uint80 maxFee;
    }

    struct ItemBook {
        uint32 dropId;
        uint80 price;
        bool sold;
        bool burned;
        address holder;
        uint32 moves;
        uint48 freeUntil;
    }

    struct ListingBook {
        bool exists;
        address seller;
        uint80 price;
        uint48 expiresAt;
        uint32 moves;
    }

    Prenda public immutable prenda;
    Venta public immutable venta;
    Mercado public immutable mercado;
    TestUSDT0 public immutable usdt;
    address public immutable admin;
    address public immutable operator;

    /// @dev Five wallets. The first four are in the snapshot of every early window; the fifth is not.
    address[] public actors;
    address[2] public treasuries;
    bytes32 public immutable snapshotRoot;

    uint32 public dropCount;
    uint256 public itemCount;
    uint256 public liveCount;
    mapping(uint32 dropId => DropBook) internal _drops;
    mapping(uint256 tokenId => ItemBook) internal _items;
    mapping(uint256 tokenId => ListingBook) internal _listings;
    mapping(uint32 dropId => mapping(address account => bool)) internal _boughtEarly;

    /// @dev Garments of the last drop, garments ever sold and garments ever offered on the market. Most operations
    /// aim at these so that the interesting paths are taken often; the rest of the time they aim anywhere.
    uint256 internal _lastDropFirstId;
    uint256 internal _lastDropSize;
    uint256[] internal _soldIds;
    uint256[] internal _offeredIds;
    mapping(uint256 tokenId => bool) internal _wasOffered;

    /// @dev What each wallet must hold: money from its sales plus money minted for purchases that did not happen.
    mapping(address account => uint256) public expectedBalance;
    /// @dev Everything the treasuries must have received: first sales, market fees and storage fees.
    uint256 public treasuryIncome;

    string[] public violations;

    uint256 public earlyPurchases;
    uint256 public publicPurchases;
    uint256 public refusedPurchases;
    uint256 public resales;
    uint256 public refusedResales;
    uint256 public paidClaims;
    uint256 public freeClaims;
    uint256 public cancelledDrops;

    constructor(
        Prenda prenda_,
        Venta venta_,
        Mercado mercado_,
        TestUSDT0 usdt_,
        address admin_,
        address operator_,
        address secondTreasury
    ) {
        prenda = prenda_;
        venta = venta_;
        mercado = mercado_;
        usdt = usdt_;
        admin = admin_;
        operator = operator_;
        treasuries = [prenda_.treasury(), secondTreasury];
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string.concat("actor ", vm.toString(i))));
        }
        snapshotRoot = Hashes.commutativeKeccak256(
            Hashes.commutativeKeccak256(_leaf(actors[0]), _leaf(actors[1])),
            Hashes.commutativeKeccak256(_leaf(actors[2]), _leaf(actors[3]))
        );
    }

    // ------------------------------------------------------------------------------------------------------ books

    function dropBook(uint32 dropId) external view returns (DropBook memory) {
        return _drops[dropId];
    }

    function itemBook(uint256 tokenId) external view returns (ItemBook memory) {
        return _items[tokenId];
    }

    function listingBook(uint256 tokenId) external view returns (ListingBook memory) {
        return _listings[tokenId];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickItem(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (itemCount == 0) return (0, false);
        return (1 + (seed % itemCount), true);
    }

    /// @dev Three times out of four a garment of the last drop, which is the one most likely to be on sale.
    function _pickForFirstSale(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (itemCount == 0) return (0, false);
        if (seed % 4 != 0) return (_lastDropFirstId + ((seed >> 8) % _lastDropSize), true);
        return (1 + ((seed >> 8) % itemCount), true);
    }

    /// @dev Seven times out of eight a garment from `preferred`, when there is any.
    function _pickFrom(uint256[] storage preferred, uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (preferred.length != 0 && seed % 8 != 0) return (preferred[(seed >> 8) % preferred.length], true);
        return _pickItem(seed >> 8);
    }

    function _leaf(address account) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    function _inSnapshot(address account) internal view returns (bool) {
        return account != actors[4];
    }

    function _proofOf(address account) internal view returns (bytes32[] memory proof) {
        if (!_inSnapshot(account)) return new bytes32[](0);
        proof = new bytes32[](2);
        if (account == actors[0] || account == actors[1]) {
            proof[0] = _leaf(account == actors[0] ? actors[1] : actors[0]);
            proof[1] = Hashes.commutativeKeccak256(_leaf(actors[2]), _leaf(actors[3]));
        } else {
            proof[0] = _leaf(account == actors[2] ? actors[3] : actors[2]);
            proof[1] = Hashes.commutativeKeccak256(_leaf(actors[0]), _leaf(actors[1]));
        }
    }

    function _marketApprovedBy(address holder, uint256 tokenId) internal view returns (bool) {
        return prenda.isApprovedForAll(holder, address(mercado)) || prenda.getApproved(tokenId) == address(mercado);
    }

    /// @dev The storage rule, from the books: free until `freeUntil`, then one instalment per full 30 days.
    function _storageFee(uint256 tokenId) internal view returns (uint256) {
        ItemBook memory item = _items[tokenId];
        DropBook memory drop = _drops[item.dropId];
        if (block.timestamp < uint256(item.freeUntil) + 30 days) return 0;
        uint256 fee = ((block.timestamp - item.freeUntil) / 30 days) * drop.feePerPeriod;
        return fee > drop.maxFee ? drop.maxFee : fee;
    }

    // ------------------------------------------------------------------------------------------------- first sale

    function createDrop(
        uint256 count,
        uint80 price,
        bool withEarlyWindow,
        uint32 freePeriod,
        uint80 feePerPeriod,
        uint80 maxFee
    ) external {
        count = bound(count, 1, 3);
        price = uint80(bound(price, MIN_PRICE, MAX_PRICE));
        freePeriod = uint32(bound(freePeriod, 0, 200 days));
        feePerPeriod = uint80(bound(feePerPeriod, 0, 20 * 10 ** 6));
        maxFee = feePerPeriod == 0 ? 0 : uint80(bound(maxFee, feePerPeriod, MAX_STORAGE));

        uint48 earlyStart = uint48(block.timestamp + DELAY);
        uint48 publicStart = withEarlyWindow ? earlyStart + EARLY_WINDOW : earlyStart;
        Venta.NewItem[] memory items = new Venta.NewItem[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = itemCount + 1 + i;
            items[i] = Venta.NewItem({
                tokenId: tokenId,
                price: price + uint80(i),
                contentHash: keccak256(abi.encode(tokenId))
            });
        }

        vm.prank(operator);
        try
            venta.createDrop(
                earlyStart,
                publicStart,
                withEarlyWindow ? snapshotRoot : bytes32(0),
                Prenda.StorageTerms({freePeriod: freePeriod, feePerPeriod: feePerPeriod, maxFee: maxFee}),
                items
            )
        returns (uint32 dropId) {
            dropCount += 1;
            if (dropId != dropCount) violations.push("drop ids do not count up");
            _drops[dropId] = DropBook({
                earlyStart: earlyStart,
                publicStart: publicStart,
                hasEarlyWindow: withEarlyWindow,
                cancelled: false,
                freePeriod: freePeriod,
                feePerPeriod: feePerPeriod,
                maxFee: maxFee
            });
            for (uint256 i = 0; i < count; i++) {
                _items[itemCount + 1 + i].dropId = dropId;
                _items[itemCount + 1 + i].price = price + uint80(i);
            }
            _lastDropFirstId = itemCount + 1;
            _lastDropSize = count;
            itemCount += count;
        } catch {
            violations.push("a valid drop could not be created");
        }
    }

    function cancelDrop(uint256 dropSeed, bool byAdmin) external {
        if (dropCount == 0) return;
        uint32 dropId = dropSeed % 2 == 0 ? dropCount : uint32(1 + ((dropSeed >> 8) % dropCount));
        DropBook memory drop = _drops[dropId];
        bool expected = !drop.cancelled && block.timestamp < drop.earlyStart;

        vm.prank(byAdmin ? admin : operator);
        try venta.cancelDrop(dropId) {
            if (!expected) violations.push("a drop that was open or already cancelled got cancelled");
            _drops[dropId].cancelled = true;
            cancelledDrops += 1;
        } catch {
            if (expected) violations.push("a drop that had not opened could not be cancelled");
        }
    }

    function buyFirstSale(uint256 tokenSeed, uint256 buyerSeed, uint256 priceTrick) external {
        (uint256 tokenId, bool ok) = _pickForFirstSale(tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        DropBook memory drop = _drops[item.dropId];
        address buyer = _actor(buyerSeed);

        // One time in eight the buyer states a price that is not the price of the garment.
        uint256 statedPrice = priceTrick % 8 == 0 ? uint256(item.price) + 1 + (priceTrick % 5) : item.price;
        bool early = block.timestamp < drop.publicStart;
        bool expected = !drop.cancelled &&
            !item.sold &&
            block.timestamp >= drop.earlyStart &&
            statedPrice == item.price &&
            (!early || (_inSnapshot(buyer) && !_boughtEarly[item.dropId][buyer])) &&
            !prenda.paused();

        vm.startPrank(buyer);
        usdt.mint(statedPrice);
        usdt.approve(address(venta), statedPrice);
        try venta.buy(tokenId, statedPrice, _proofOf(buyer)) {
            if (!expected) violations.push("a first sale that should have failed went through");
            _items[tokenId].sold = true;
            _items[tokenId].holder = buyer;
            _items[tokenId].freeUntil = uint48(block.timestamp + drop.freePeriod);
            _soldIds.push(tokenId);
            liveCount += 1;
            treasuryIncome += statedPrice;
            if (early) {
                _boughtEarly[item.dropId][buyer] = true;
                earlyPurchases += 1;
            } else {
                publicPurchases += 1;
            }
        } catch {
            if (expected) violations.push("a valid first sale failed");
            expectedBalance[buyer] += statedPrice;
            refusedPurchases += 1;
        }
        usdt.approve(address(venta), 0);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------------------------------------- market

    function approveMarket(uint256 actorSeed, bool approved) external {
        vm.prank(_actor(actorSeed));
        prenda.setApprovalForAll(address(mercado), approved);
    }

    function list(uint256 tokenSeed, uint80 price, uint48 duration, bool byHolder, uint256 otherSeed) external {
        (uint256 tokenId, bool ok) = _pickFrom(_soldIds, tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        price = uint80(bound(price, MIN_PRICE, MAX_PRICE));
        uint48 expiresAt = uint48(block.timestamp + bound(duration, 1, MAX_LISTING));
        bool alive = item.sold && !item.burned;
        address caller = byHolder && alive ? item.holder : _actor(otherSeed);
        if (otherSeed % 2 == 0) {
            vm.prank(caller);
            prenda.setApprovalForAll(address(mercado), true);
        }
        bool expected = alive && caller == item.holder && _marketApprovedBy(caller, tokenId);

        vm.prank(caller);
        try mercado.list(tokenId, price, expiresAt) {
            if (!expected) violations.push("an offer was made by someone who could not make it");
            _listings[tokenId] = ListingBook({
                exists: true,
                seller: caller,
                price: price,
                expiresAt: expiresAt,
                moves: item.moves
            });
            if (!_wasOffered[tokenId]) {
                _wasOffered[tokenId] = true;
                _offeredIds.push(tokenId);
            }
        } catch {
            if (expected) violations.push("a valid offer could not be made");
        }
    }

    function cancelListing(uint256 tokenSeed, bool bySeller, uint256 otherSeed) external {
        (uint256 tokenId, bool ok) = _pickFrom(_offeredIds, tokenSeed);
        if (!ok) return;
        ListingBook memory listing = _listings[tokenId];
        address caller = bySeller && listing.exists ? listing.seller : _actor(otherSeed);
        bool expected = listing.exists && caller == listing.seller;

        vm.prank(caller);
        try mercado.cancel(tokenId) {
            if (!expected) violations.push("an offer was withdrawn by someone who did not make it");
            delete _listings[tokenId];
        } catch {
            if (expected) violations.push("a seller could not withdraw an offer");
        }
    }

    function buyOnMarket(uint256 tokenSeed, uint256 buyerSeed, uint256 priceTrick) external {
        (uint256 tokenId, bool ok) = _pickFrom(_offeredIds, tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        ListingBook memory listing = _listings[tokenId];
        address buyer = _actor(buyerSeed);
        // The buyer brings the listed price, or a small price when nothing is listed or to try a wrong price.
        uint256 statedPrice = !listing.exists || priceTrick % 8 == 0
            ? uint256(MIN_PRICE) + (priceTrick % 7)
            : listing.price;

        bool expected = listing.exists &&
            block.timestamp <= listing.expiresAt &&
            statedPrice == listing.price &&
            item.sold &&
            !item.burned &&
            item.holder == listing.seller &&
            item.moves == listing.moves &&
            _marketApprovedBy(listing.seller, tokenId) &&
            !prenda.paused();

        vm.startPrank(buyer);
        usdt.mint(statedPrice);
        usdt.approve(address(mercado), statedPrice);
        try mercado.buy(tokenId, statedPrice) {
            if (!expected) violations.push("a resale that should have failed went through");
            uint256 fee = (statedPrice * 2) / 100;
            expectedBalance[listing.seller] += statedPrice - fee;
            treasuryIncome += fee;
            _items[tokenId].holder = buyer;
            _items[tokenId].moves += 1;
            delete _listings[tokenId];
            resales += 1;
        } catch {
            if (expected) violations.push("a valid resale failed");
            expectedBalance[buyer] += statedPrice;
            refusedResales += 1;
        }
        usdt.approve(address(mercado), 0);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------------------------------------- claims

    function claim(uint256 tokenSeed) external {
        (uint256 tokenId, bool ok) = _pickFrom(_soldIds, tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        if (!item.sold || item.burned) return;
        uint256 fee = _storageFee(tokenId);
        if (prenda.storageFeeOf(tokenId) != fee) violations.push("the storage fee is not what the drop promised");

        vm.startPrank(item.holder);
        usdt.mint(fee);
        usdt.approve(address(prenda), fee);
        try prenda.claim(tokenId, fee) {
            _items[tokenId].burned = true;
            liveCount -= 1;
            treasuryIncome += fee;
            if (fee == 0) freeClaims += 1;
            else paidClaims += 1;
        } catch {
            violations.push("a holder could not claim");
            expectedBalance[item.holder] += fee;
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------ things nobody may do

    function tryWhatMustFail(uint256 tokenSeed, uint256 actorSeed, uint256 otherSeed) external {
        address actor = _actor(actorSeed);
        address other = _actor(otherSeed);

        // Only the operator creates drops and only the administration names the operator.
        Venta.NewItem[] memory items = new Venta.NewItem[](1);
        items[0] = Venta.NewItem({tokenId: itemCount + 1, price: MIN_PRICE, contentHash: keccak256("x")});
        uint48 start = uint48(block.timestamp + DELAY);
        vm.prank(actor);
        try venta.createDrop(start, start, bytes32(0), Prenda.StorageTerms(0, 0, 0), items) {
            violations.push("someone who is not the operator created a drop");
        } catch {}
        vm.prank(actor);
        try venta.setOperator(actor) {
            violations.push("someone who is not the administration named the operator");
        } catch {}

        (uint256 tokenId, bool ok) = _pickItem(tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        if (!item.sold || item.burned) return;

        // Nobody moves an NFT outside the market, not even its holder, and nobody claims for somebody else.
        vm.prank(actor);
        try prenda.transferFrom(item.holder, other, tokenId) {
            violations.push("an NFT moved outside the market");
        } catch {}
        if (actor != item.holder) {
            vm.prank(actor);
            try prenda.claim(tokenId, type(uint256).max) {
                violations.push("someone claimed a garment that is not theirs");
            } catch {}
        }
    }

    // --------------------------------------------------------------------------------------------- administration

    function setPaused(bool paused) external {
        if (paused == prenda.paused()) return;
        vm.prank(admin);
        if (paused) prenda.pause();
        else prenda.unpause();
    }

    function changeTreasury(uint256 seed) external {
        vm.prank(admin);
        prenda.setTreasury(treasuries[seed % 2]);
    }

    function letTimePass(uint32 time, bool long_) external {
        vm.warp(block.timestamp + bound(time, 1, long_ ? 90 days : 4 hours));
    }

    /// @dev Moves the clock to the moment the last drop opens, if that is still ahead.
    function waitForTheLastDropToOpen() external {
        if (dropCount == 0) return;
        uint48 opening = _drops[dropCount].earlyStart;
        if (block.timestamp < opening) vm.warp(opening);
    }
}

contract ArchivoInvariantTest is Test {
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal secondTreasury = makeAddr("second treasury");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    Venta internal venta;
    Mercado internal mercado;
    ArchivoHandler internal handler;

    function setUp() public {
        usdt = new TestUSDT0();
        prenda = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, "https://example.test/nft/");
        venta = new Venta(prenda, operator, 1 hours, 10 * 10 ** 6, 100 * 10 ** 6);
        mercado = new Mercado(prenda, 10 * 10 ** 6, 30 days);
        vm.startPrank(admin);
        prenda.setMinter(address(venta), true);
        prenda.authorizeMarket(address(mercado));
        vm.stopPrank();

        handler = new ArchivoHandler(prenda, venta, mercado, usdt, admin, operator, secondTreasury);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = ArchivoHandler.createDrop.selector;
        selectors[1] = ArchivoHandler.cancelDrop.selector;
        selectors[2] = ArchivoHandler.buyFirstSale.selector;
        selectors[3] = ArchivoHandler.approveMarket.selector;
        selectors[4] = ArchivoHandler.list.selector;
        selectors[5] = ArchivoHandler.cancelListing.selector;
        selectors[6] = ArchivoHandler.buyOnMarket.selector;
        selectors[7] = ArchivoHandler.claim.selector;
        selectors[8] = ArchivoHandler.tryWhatMustFail.selector;
        selectors[9] = ArchivoHandler.setPaused.selector;
        selectors[10] = ArchivoHandler.changeTreasury.selector;
        selectors[11] = ArchivoHandler.letTimePass.selector;
        selectors[12] = ArchivoHandler.waitForTheLastDropToOpen.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Everything that should work worked, and everything that should fail failed.
    function invariant_EveryOperationEndedAsTheBooksExpected() public view {
        if (handler.violationCount() != 0) revert(handler.violations(0));
    }

    /// @dev No contract holds money or NFTs, and every unit of money is where the books say.
    function invariant_MoneyIsWhereTheBooksSay() public view {
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(usdt.balanceOf(address(venta)), 0);
        assertEq(usdt.balanceOf(address(mercado)), 0);
        assertEq(prenda.balanceOf(address(venta)), 0);
        assertEq(prenda.balanceOf(address(mercado)), 0);

        assertEq(usdt.balanceOf(treasury) + usdt.balanceOf(secondTreasury), handler.treasuryIncome());
        uint256 heldByWallets;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(usdt.balanceOf(actor), handler.expectedBalance(actor));
            heldByWallets += usdt.balanceOf(actor);
        }
        assertEq(usdt.totalSupply(), handler.treasuryIncome() + heldByWallets);
    }

    /// @dev Every garment ever put on sale: who holds its NFT, whether it was sold and how often it changed hands.
    function invariant_EveryGarmentMatchesTheBooks() public view {
        uint256 count = handler.itemCount();
        uint256 alive;
        for (uint256 tokenId = 1; tokenId <= count; tokenId++) {
            ArchivoHandler.ItemBook memory item = handler.itemBook(tokenId);
            (uint32 dropId, uint80 price, bool sold, bytes32 contentHash) = venta.itemOf(tokenId);
            assertEq(dropId, item.dropId);
            assertEq(price, item.price);
            assertEq(sold, item.sold);
            assertEq(contentHash, keccak256(abi.encode(tokenId)));
            assertEq(prenda.isTokenIdUsed(tokenId), item.sold);
            assertEq(prenda.transferCountOf(tokenId), item.moves);

            if (item.sold && !item.burned) {
                alive += 1;
                assertEq(prenda.ownerOf(tokenId), item.holder);
                assertEq(prenda.contentHashOf(tokenId), contentHash);
                (uint48 freeUntil, , ) = prenda.storageTermsOf(tokenId);
                assertEq(freeUntil, item.freeUntil);
            } else {
                try prenda.ownerOf(tokenId) returns (address) {
                    revert("an NFT that was not sold, or was burned, has a holder");
                } catch {}
            }

            ArchivoHandler.ListingBook memory listing = handler.listingBook(tokenId);
            Mercado.Listing memory recorded = mercado.listingOf(tokenId);
            assertEq(recorded.seller, listing.exists ? listing.seller : address(0));
            assertEq(recorded.price, listing.price);
        }
        assertEq(alive, handler.liveCount());

        uint256 held;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += prenda.balanceOf(handler.actors(i));
        }
        assertEq(held, alive);
    }

    /**
     * @dev The same handler driven by a fixed pseudo-random sequence, so that the run is always the same and the
     * test can check that every kind of operation really happened.
     */
    function test_FixedRandomWalkOverTheThreeContracts() public {
        uint256 steps = 2500;
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode("archivo", i)));
            uint256 a = uint256(keccak256(abi.encode(r, uint256(1))));
            uint256 b = uint256(keccak256(abi.encode(r, uint256(2))));
            uint256 c = uint256(keccak256(abi.encode(r, uint256(3))));
            uint256 kind = r % 100;

            if (kind < 8) {
                handler.createDrop(a, uint80(b), c % 2 == 0, uint32(a >> 96), uint80(b >> 96), uint80(c >> 96));
            } else if (kind < 10) handler.cancelDrop(a, b % 2 == 0);
            else if (kind < 14) handler.waitForTheLastDropToOpen();
            else if (kind < 36) handler.buyFirstSale(a, b, c);
            else if (kind < 40) handler.approveMarket(a, b % 5 != 0);
            else if (kind < 56) handler.list(a, uint80(b), uint48(c), c % 6 != 0, b >> 8);
            else if (kind < 60) handler.cancelListing(a, b % 3 != 0, c);
            else if (kind < 78) handler.buyOnMarket(a, b, c);
            else if (kind < 84) handler.claim(a);
            else if (kind < 88) handler.tryWhatMustFail(a, b, c);
            else if (kind < 90) handler.setPaused(a % 3 == 0);
            else if (kind < 92) handler.changeTreasury(a);
            else handler.letTimePass(uint32(a), b % 12 == 0);

            if (i % 100 == 0) _checkEverything();
        }
        _checkEverything();

        // The walk must really have gone through every kind of operation.
        assertGt(handler.dropCount(), 100);
        assertGt(handler.cancelledDrops(), 5);
        assertGt(handler.earlyPurchases(), 10);
        assertGt(handler.publicPurchases(), 50);
        assertGt(handler.refusedPurchases(), 100);
        assertGt(handler.resales(), 20);
        assertGt(handler.refusedResales(), 100);
        assertGt(handler.paidClaims(), 15);
        assertGt(handler.freeClaims(), 15);
    }

    function _checkEverything() internal view {
        invariant_EveryOperationEndedAsTheBooksExpected();
        invariant_MoneyIsWhereTheBooksSay();
        invariant_EveryGarmentMatchesTheBooks();
    }
}
