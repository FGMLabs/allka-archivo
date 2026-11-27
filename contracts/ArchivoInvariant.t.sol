// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {Mercado} from "./Mercado.sol";
import {Prenda} from "./Prenda.sol";
import {Venta} from "./Venta.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

/**
 * @notice Random sequences over the three contracts together: drops are created and closed, garments that were not
 * sold go into new drops, garments are bought in the early window and after it, NFTs are offered, bought and
 * re-offered on the market, they also change hands through a second market, approvals are given and taken back,
 * garments are claimed, and in between the clock moves, sales are paused and the treasury changes.
 *
 * Before every operation the handler works out, from its own books, whether the operation should succeed. A result
 * that does not match is written down as a violation. The books also follow every unit of money: what each wallet
 * must hold and what each treasury must have received. The books never read the contracts to decide: approvals,
 * approvals taken back, the pause, the treasury in force and every date are kept on the side and compared with the
 * contracts afterwards.
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
        bool closed;
        uint32 freePeriod;
        uint80 feePerPeriod;
        uint80 maxFee;
        uint256 firstId;
        uint256 size;
    }

    struct ItemBook {
        uint32 dropId;
        uint80 price;
        bool sold;
        bool burned;
        address holder;
        uint32 moves;
        uint48 freeUntil;
        /// The account approved for this one NFT: the market, the other market or nobody.
        address approved;
    }

    struct ListingBook {
        bool exists;
        address seller;
        uint80 price;
        uint48 expiresAt;
        uint32 moves;
        uint64 revokedForAll;
        uint64 revokedForNft;
    }

    /// @dev Why an offer cannot be taken, by the books. The first reason that applies, in this order.
    enum Refusal {
        None,
        Offer,
        Hands,
        NotApproved,
        ForAllTakenBack,
        NftTakenBack
    }

    Prenda public immutable prenda;
    Venta public immutable venta;
    Mercado public immutable mercado;
    /// @dev A second authorized market, through which NFTs change hands behind the back of the first.
    OpenMarketMock public immutable otherMarket;
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

    /// @dev Whether each wallet approves the market for all its NFTs, how many times it took that approval back,
    /// and how many times the approval of each NFT was taken back from the market.
    mapping(address account => bool) public approvesMarket;
    mapping(address account => uint64) public revokedForAllBook;
    mapping(uint256 tokenId => uint64) public revokedForNftBook;
    bool public pausedBook;
    /// @dev The treasury in force.
    address public treasuryBook;

    /// @dev The last drop, the last drop that was closed, garments ever sold and garments ever offered on the
    /// market. Most operations aim at these so that the interesting paths are taken often; the rest of the time
    /// they aim anywhere.
    uint32 internal _lastClosedDrop;
    uint256[] internal _soldIds;
    uint256[] internal _offeredIds;
    mapping(uint256 tokenId => bool) internal _wasOffered;
    uint256 internal _lastOffered;

    /// @dev What each wallet must hold: money from its sales plus money minted for purchases that did not happen.
    mapping(address account => uint256) public expectedBalance;
    /// @dev Everything the treasuries must have received: first sales, market fees and storage fees. In total,
    /// and for each treasury what came in while it was the one in force.
    uint256 public treasuryIncome;
    mapping(address treasury => uint256) public treasuryIncomeOf;

    string[] public violations;

    uint256 public earlyPurchases;
    uint256 public publicPurchases;
    uint256 public refusedPurchases;
    uint256 public purchasesRefusedForTheDrop;
    uint256 public offersMade;
    uint256 public resales;
    uint256 public refusedResales;
    uint256 public resalesUnderOneNftApproval;
    uint256 public staleOffersRefused;
    uint256 public offersRefusedForAllTakenBack;
    uint256 public offersRefusedForNftTakenBack;
    uint256 public nftApprovalsCleared;
    uint256 public nftApprovalsReplaced;
    uint256 public paidClaims;
    uint256 public freeClaims;
    uint256 public dropsClosedBeforeOpening;
    uint256 public dropsClosedWhileOpen;
    uint256 public garmentsRelisted;
    uint256 public refusedRelistings;
    uint256 public movesOutside;

    constructor(
        Prenda prenda_,
        Venta venta_,
        Mercado mercado_,
        OpenMarketMock otherMarket_,
        TestUSDT0 usdt_,
        address admin_,
        address operator_,
        address secondTreasury
    ) {
        prenda = prenda_;
        venta = venta_;
        mercado = mercado_;
        otherMarket = otherMarket_;
        usdt = usdt_;
        admin = admin_;
        operator = operator_;
        treasuries = [prenda_.treasury(), secondTreasury];
        treasuryBook = treasuries[0];
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

    /// @dev The fingerprint the handler gives a garment: it changes with every drop the garment goes into.
    function fingerprint(uint256 tokenId, uint32 dropId) public pure returns (bytes32) {
        return keccak256(abi.encode(tokenId, dropId));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickItem(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (itemCount == 0) return (0, false);
        return (1 + (seed % itemCount), true);
    }

    /// @dev Three times out of four a garment of `dropId`, when that drop exists; otherwise any garment.
    function _pickInDrop(uint32 dropId, uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (itemCount == 0) return (0, false);
        if (dropId != 0 && seed % 4 != 0) return (_drops[dropId].firstId + ((seed >> 8) % _drops[dropId].size), true);
        return (1 + ((seed >> 8) % itemCount), true);
    }

    /// @dev Seven times out of eight a garment from `preferred`, when there is any.
    function _pickFrom(uint256[] storage preferred, uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (preferred.length != 0 && seed % 8 != 0) return (preferred[(seed >> 8) % preferred.length], true);
        return _pickItem(seed >> 8);
    }

    /// @dev Half of the time the garment that was offered last, which is the one most likely to have an offer
    /// that still stands; otherwise as {_pickFrom} with the garments ever offered.
    function _pickOffered(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (_lastOffered != 0 && seed % 2 == 0) return (_lastOffered, true);
        return _pickFrom(_offeredIds, seed >> 1);
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

    /// @dev From the books: the holder approved the market for all its NFTs or for this one.
    function _marketApprovedBy(address holder, uint256 tokenId) internal view returns (bool) {
        return approvesMarket[holder] || _items[tokenId].approved == address(mercado);
    }

    /// @dev Money that must have reached the treasury in force.
    function _toTreasury(uint256 amount) internal {
        treasuryIncome += amount;
        treasuryIncomeOf[treasuryBook] += amount;
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
                contentHash: fingerprint(tokenId, dropCount + 1)
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
                closed: false,
                freePeriod: freePeriod,
                feePerPeriod: feePerPeriod,
                maxFee: maxFee,
                firstId: itemCount + 1,
                size: count
            });
            for (uint256 i = 0; i < count; i++) {
                _items[itemCount + 1 + i].dropId = dropId;
                _items[itemCount + 1 + i].price = price + uint80(i);
            }
            itemCount += count;
        } catch {
            violations.push("a valid drop could not be created");
        }
    }

    /// @dev A drop can be closed at any moment, by the operator or by the administration, but only once.
    function closeDrop(uint256 dropSeed, bool byAdmin) external {
        if (dropCount == 0) return;
        uint32 dropId = dropSeed % 4 == 0 ? dropCount : uint32(1 + ((dropSeed >> 8) % dropCount));
        DropBook memory drop = _drops[dropId];
        bool expected = !drop.closed;

        vm.prank(byAdmin ? admin : operator);
        try venta.closeDrop(dropId) {
            if (!expected) violations.push("a drop was closed twice");
            _drops[dropId].closed = true;
            _lastClosedDrop = dropId;
            if (block.timestamp < drop.earlyStart) dropsClosedBeforeOpening += 1;
            else dropsClosedWhileOpen += 1;
        } catch {
            if (expected) violations.push("a drop could not be closed");
        }
    }

    /**
     * @dev Tries to put a number that was already in a drop into a new drop. It must work only for a garment that
     * was not sold and whose drop was closed; then the garment takes the price, the dates and the fingerprint of
     * the new drop.
     */
    function createDropWithAUsedNumber(uint256 tokenSeed, uint80 price, bool withEarlyWindow) external {
        (uint256 tokenId, bool ok) = _pickInDrop(_lastClosedDrop, tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        price = uint80(bound(price, MIN_PRICE, MAX_PRICE));
        bool expected = !item.sold && _drops[item.dropId].closed;

        uint48 earlyStart = uint48(block.timestamp + DELAY);
        uint48 publicStart = withEarlyWindow ? earlyStart + EARLY_WINDOW : earlyStart;
        Venta.NewItem[] memory items = new Venta.NewItem[](1);
        items[0] = Venta.NewItem({tokenId: tokenId, price: price, contentHash: fingerprint(tokenId, dropCount + 1)});

        vm.prank(operator);
        try
            venta.createDrop(
                earlyStart,
                publicStart,
                withEarlyWindow ? snapshotRoot : bytes32(0),
                Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}),
                items
            )
        returns (uint32 dropId) {
            if (!expected) violations.push("a number that was sold, or is in an open drop, went into a new drop");
            dropCount += 1;
            if (dropId != dropCount) violations.push("drop ids do not count up");
            _drops[dropId] = DropBook({
                earlyStart: earlyStart,
                publicStart: publicStart,
                hasEarlyWindow: withEarlyWindow,
                closed: false,
                freePeriod: 0,
                feePerPeriod: 0,
                maxFee: 0,
                firstId: tokenId,
                size: 1
            });
            _items[tokenId].dropId = dropId;
            _items[tokenId].price = price;
            garmentsRelisted += 1;
        } catch {
            if (expected) violations.push("an unsold garment of a closed drop could not go into a new drop");
            refusedRelistings += 1;
        }
    }

    function buyFirstSale(uint256 tokenSeed, uint256 buyerSeed, uint256 trick) external {
        (uint256 tokenId, bool ok) = _pickInDrop(dropCount, tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        DropBook memory drop = _drops[item.dropId];
        address buyer = _actor(buyerSeed);

        // One time in eight the buyer states a price that is not the price of the garment, and one time in eight
        // a drop picked at random, which is seldom the drop of the garment.
        uint256 statedPrice = trick % 8 == 0 ? uint256(item.price) + 1 + (trick % 5) : item.price;
        uint32 statedDrop = (trick >> 8) % 8 == 0 ? uint32((trick >> 16) % (uint256(dropCount) + 2)) : item.dropId;
        bool early = block.timestamp < drop.publicStart;
        bool expectedButForTheDrop = !drop.closed &&
            !item.sold &&
            block.timestamp >= drop.earlyStart &&
            statedPrice == item.price &&
            (!early || (_inSnapshot(buyer) && !_boughtEarly[item.dropId][buyer])) &&
            !pausedBook;
        bool expected = expectedButForTheDrop && statedDrop == item.dropId;

        vm.startPrank(buyer);
        usdt.mint(statedPrice);
        usdt.approve(address(venta), statedPrice);
        try venta.buy(tokenId, statedDrop, statedPrice, _proofOf(buyer)) {
            if (!expected) violations.push("a first sale that should have failed went through");
            _items[tokenId].sold = true;
            _items[tokenId].holder = buyer;
            _items[tokenId].freeUntil = uint48(block.timestamp + drop.freePeriod);
            _soldIds.push(tokenId);
            liveCount += 1;
            _toTreasury(statedPrice);
            if (early) {
                _boughtEarly[item.dropId][buyer] = true;
                earlyPurchases += 1;
            } else {
                publicPurchases += 1;
            }
        } catch {
            if (expected) violations.push("a valid first sale failed");
            if (expectedButForTheDrop && !expected) purchasesRefusedForTheDrop += 1;
            expectedBalance[buyer] += statedPrice;
            refusedPurchases += 1;
        }
        usdt.approve(address(venta), 0);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------------------------------------- market

    function approveMarket(uint256 actorSeed, bool approved) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        prenda.setApprovalForAll(address(mercado), approved);
        if (!approved && approvesMarket[actor]) revokedForAllBook[actor] += 1;
        approvesMarket[actor] = approved;
    }

    /// @dev The holder approves the market for one NFT only (half of the time), gives that approval to the other
    /// market, or clears it.
    function approveMarketForOneNft(uint256 tokenSeed, uint256 choice) external {
        (uint256 tokenId, bool ok) = _pickFrom(_soldIds, tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        if (!item.sold || item.burned) return;
        address to = choice % 4 == 0 ? address(0) : choice % 4 == 1 ? address(otherMarket) : address(mercado);

        vm.prank(item.holder);
        prenda.approve(to, tokenId);
        _noteApprovalOfOneNft(tokenId, to);
    }

    /// @dev Books for the approval of one NFT: it counts as taken back from the market when the market had it and
    /// it is cleared or goes to somebody else.
    function _noteApprovalOfOneNft(uint256 tokenId, address to) internal {
        if (_items[tokenId].approved == address(mercado) && to != address(mercado)) {
            revokedForNftBook[tokenId] += 1;
            if (to == address(0)) nftApprovalsCleared += 1;
            else nftApprovalsReplaced += 1;
        }
        _items[tokenId].approved = to;
    }

    /**
     * @dev A seller with an open offer takes an approval back from the market and gives it again right away. With
     * `mode` 0 it is the approval for all its NFTs; with 1 the approval of the NFT on offer, cleared and given
     * again; with 2 that same approval, given to the other market and back. The offer must be dead from then on.
     */
    function takeApprovalBackAndGiveItAgain(uint256 tokenSeed, uint256 mode) external {
        (uint256 tokenId, bool ok) = _pickOffered(tokenSeed);
        if (!ok) return;
        ListingBook memory listing = _listings[tokenId];
        if (!listing.exists) return;
        mode = mode % 3;

        if (mode == 0) {
            if (!approvesMarket[listing.seller]) return;
            vm.startPrank(listing.seller);
            prenda.setApprovalForAll(address(mercado), false);
            prenda.setApprovalForAll(address(mercado), true);
            vm.stopPrank();
            revokedForAllBook[listing.seller] += 1;
            return;
        }

        // Only the holder can touch the approval of the NFT, and there has to be one to take back.
        ItemBook memory item = _items[tokenId];
        if (!item.sold || item.burned || item.holder != listing.seller || item.approved != address(mercado)) return;
        address through = mode == 1 ? address(0) : address(otherMarket);
        vm.startPrank(listing.seller);
        prenda.approve(through, tokenId);
        prenda.approve(address(mercado), tokenId);
        vm.stopPrank();
        _noteApprovalOfOneNft(tokenId, through);
        _noteApprovalOfOneNft(tokenId, address(mercado));
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
            approvesMarket[caller] = true;
        }
        bool expected = alive && caller == item.holder && _marketApprovedBy(caller, tokenId);

        vm.prank(caller);
        try mercado.list(tokenId, price, expiresAt) {
            if (!expected) violations.push("an offer was made by someone who could not make it");
            _noteOffer(tokenId, caller, price, expiresAt);
        } catch {
            if (expected) violations.push("a valid offer could not be made");
        }
    }

    /// @dev A holder that does not approve the market for all its NFTs approves it for one of them and offers it.
    function offerUnderTheApprovalOfOneNft(uint256 tokenSeed, uint80 price, uint48 duration) external {
        (uint256 tokenId, bool ok) = _pickFrom(_soldIds, tokenSeed);
        if (!ok) return;
        address holder = _items[tokenId].holder;
        if (!_items[tokenId].sold || _items[tokenId].burned) return;
        price = uint80(bound(price, MIN_PRICE, MAX_PRICE));
        uint48 expiresAt = uint48(block.timestamp + bound(duration, 1, MAX_LISTING));

        vm.startPrank(holder);
        if (approvesMarket[holder]) {
            prenda.setApprovalForAll(address(mercado), false);
            revokedForAllBook[holder] += 1;
            approvesMarket[holder] = false;
        }
        prenda.approve(address(mercado), tokenId);
        _noteApprovalOfOneNft(tokenId, address(mercado));
        try mercado.list(tokenId, price, expiresAt) {
            _noteOffer(tokenId, holder, price, expiresAt);
        } catch {
            violations.push("a valid offer under the approval of one NFT could not be made");
        }
        vm.stopPrank();
    }

    /// @dev Books for an offer that was just made: it records what the market must have recorded.
    function _noteOffer(uint256 tokenId, address seller, uint80 price, uint48 expiresAt) internal {
        _listings[tokenId] = ListingBook({
            exists: true,
            seller: seller,
            price: price,
            expiresAt: expiresAt,
            moves: _items[tokenId].moves,
            revokedForAll: revokedForAllBook[seller],
            revokedForNft: revokedForNftBook[tokenId]
        });
        if (!_wasOffered[tokenId]) {
            _wasOffered[tokenId] = true;
            _offeredIds.push(tokenId);
        }
        _lastOffered = tokenId;
        offersMade += 1;
    }

    function cancelListing(uint256 tokenSeed, bool bySeller, uint256 otherSeed) external {
        (uint256 tokenId, bool ok) = _pickOffered(tokenSeed);
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
        (uint256 tokenId, bool ok) = _pickOffered(tokenSeed);
        if (!ok) return;
        ListingBook memory listing = _listings[tokenId];
        address buyer = _actor(buyerSeed);
        // The buyer brings the listed price, or a small price when nothing is listed or to try a wrong price.
        uint256 statedPrice = !listing.exists || priceTrick % 8 == 0
            ? uint256(MIN_PRICE) + (priceTrick % 7)
            : listing.price;
        Refusal refusal = _refusal(tokenId, statedPrice);

        vm.startPrank(buyer);
        usdt.mint(statedPrice);
        usdt.approve(address(mercado), statedPrice);
        try mercado.buy(tokenId, statedPrice) {
            if (refusal != Refusal.None) violations.push("a resale that should have failed went through");
            uint256 fee = (statedPrice * 2) / 100;
            expectedBalance[listing.seller] += statedPrice - fee;
            _toTreasury(fee);
            if (!approvesMarket[listing.seller]) resalesUnderOneNftApproval += 1;
            _items[tokenId].holder = buyer;
            _items[tokenId].moves += 1;
            _items[tokenId].approved = address(0);
            delete _listings[tokenId];
            resales += 1;
        } catch {
            if (refusal == Refusal.None) violations.push("a valid resale failed");
            else if (refusal == Refusal.Hands) staleOffersRefused += 1;
            else if (refusal == Refusal.ForAllTakenBack) offersRefusedForAllTakenBack += 1;
            else if (refusal == Refusal.NftTakenBack) offersRefusedForNftTakenBack += 1;
            expectedBalance[buyer] += statedPrice;
            refusedResales += 1;
        }
        usdt.approve(address(mercado), 0);
        vm.stopPrank();
    }

    /// @dev From the books: whether the offer of `tokenId` can be taken at `statedPrice`, and if not, why.
    function _refusal(uint256 tokenId, uint256 statedPrice) internal view returns (Refusal) {
        ItemBook memory item = _items[tokenId];
        ListingBook memory listing = _listings[tokenId];
        // Everything about the offer itself, the NFT and the pause...
        if (
            !listing.exists ||
            block.timestamp > listing.expiresAt ||
            statedPrice != listing.price ||
            !item.sold ||
            item.burned ||
            pausedBook
        ) return Refusal.Offer;
        // ...the NFT is still in the hands it was in...
        if (item.holder != listing.seller || item.moves != listing.moves) return Refusal.Hands;
        // ...the market can still move it...
        if (!_marketApprovedBy(listing.seller, tokenId)) return Refusal.NotApproved;
        // ...and since the offer was made the seller took back neither the approval for all nor the one of the NFT.
        if (revokedForAllBook[listing.seller] != listing.revokedForAll) return Refusal.ForAllTakenBack;
        if (revokedForNftBook[tokenId] != listing.revokedForNft) return Refusal.NftTakenBack;
        return Refusal.None;
    }

    /// @dev The NFT changes hands through the other market, and maybe comes back. Its offer here is left behind.
    function moveOutside(uint256 tokenSeed, uint256 toSeed, bool andBack) external {
        (uint256 tokenId, bool ok) = _pickOffered(tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        if (!item.sold || item.burned || pausedBook) return;
        address to = _actor(toSeed);

        vm.prank(item.holder);
        prenda.setApprovalForAll(address(otherMarket), true);
        otherMarket.move(item.holder, to, tokenId);
        _items[tokenId].moves += 1;
        _items[tokenId].approved = address(0);
        if (andBack) {
            vm.prank(to);
            prenda.setApprovalForAll(address(otherMarket), true);
            otherMarket.move(to, item.holder, tokenId);
            _items[tokenId].moves += 1;
        } else {
            _items[tokenId].holder = to;
        }
        movesOutside += 1;
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
        try prenda.claim(tokenId, fee, bytes32(tokenId)) {
            _items[tokenId].burned = true;
            _items[tokenId].approved = address(0);
            liveCount -= 1;
            _toTreasury(fee);
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

        // Only the operator creates drops, only the operator and the administration close them, and only the
        // administration names the operator.
        Venta.NewItem[] memory items = new Venta.NewItem[](1);
        items[0] = Venta.NewItem({tokenId: itemCount + 1, price: MIN_PRICE, contentHash: keccak256("x")});
        uint48 start = uint48(block.timestamp + DELAY);
        vm.prank(actor);
        try venta.createDrop(start, start, bytes32(0), Prenda.StorageTerms(0, 0, 0), items) {
            violations.push("someone who is not the operator created a drop");
        } catch {}
        if (dropCount != 0) {
            vm.prank(actor);
            try venta.closeDrop(uint32(1 + (otherSeed % dropCount))) {
                violations.push("someone who is neither the operator nor the administration closed a drop");
            } catch {}
        }
        vm.prank(actor);
        try venta.setOperator(actor) {
            violations.push("someone who is not the administration named the operator");
        } catch {}

        (uint256 tokenId, bool ok) = _pickItem(tokenSeed);
        if (!ok) return;
        ItemBook memory item = _items[tokenId];
        if (!item.sold || item.burned) return;

        // Nobody moves an NFT outside a market, not even its holder, and nobody claims for somebody else.
        vm.prank(actor);
        try prenda.transferFrom(item.holder, other, tokenId) {
            violations.push("an NFT moved outside the market");
        } catch {}
        if (actor != item.holder) {
            vm.prank(actor);
            try prenda.claim(tokenId, type(uint256).max, bytes32(tokenId)) {
                violations.push("someone claimed a garment that is not theirs");
            } catch {}
        }
    }

    // --------------------------------------------------------------------------------------------- administration

    function setPaused(bool paused) external {
        if (paused == pausedBook) return;
        vm.prank(admin);
        if (paused) prenda.pause();
        else prenda.unpause();
        pausedBook = paused;
    }

    function changeTreasury(uint256 seed) external {
        address next = treasuries[seed % 2];
        vm.prank(admin);
        prenda.proposeTreasury(next);
        vm.prank(next);
        prenda.acceptTreasury();
        treasuryBook = next;
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
    OpenMarketMock internal otherMarket;
    ArchivoHandler internal handler;

    function setUp() public {
        usdt = new TestUSDT0();
        prenda = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, "https://example.test/nft/");
        venta = new Venta(prenda, operator, 1 hours, 10 * 10 ** 6, 100 * 10 ** 6);
        mercado = new Mercado(prenda, 10 * 10 ** 6);
        otherMarket = new OpenMarketMock(prenda);
        vm.startPrank(admin);
        prenda.setMinter(address(venta), true);
        prenda.authorizeMarket(address(mercado));
        prenda.authorizeMarket(address(otherMarket));
        vm.stopPrank();

        handler = new ArchivoHandler(prenda, venta, mercado, otherMarket, usdt, admin, operator, secondTreasury);

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = ArchivoHandler.createDrop.selector;
        selectors[1] = ArchivoHandler.closeDrop.selector;
        selectors[2] = ArchivoHandler.createDropWithAUsedNumber.selector;
        selectors[3] = ArchivoHandler.buyFirstSale.selector;
        selectors[4] = ArchivoHandler.approveMarket.selector;
        selectors[5] = ArchivoHandler.approveMarketForOneNft.selector;
        selectors[6] = ArchivoHandler.list.selector;
        selectors[7] = ArchivoHandler.cancelListing.selector;
        selectors[8] = ArchivoHandler.buyOnMarket.selector;
        selectors[9] = ArchivoHandler.moveOutside.selector;
        selectors[10] = ArchivoHandler.claim.selector;
        selectors[11] = ArchivoHandler.tryWhatMustFail.selector;
        selectors[12] = ArchivoHandler.setPaused.selector;
        selectors[13] = ArchivoHandler.changeTreasury.selector;
        selectors[14] = ArchivoHandler.letTimePass.selector;
        selectors[15] = ArchivoHandler.waitForTheLastDropToOpen.selector;
        selectors[16] = ArchivoHandler.takeApprovalBackAndGiveItAgain.selector;
        selectors[17] = ArchivoHandler.offerUnderTheApprovalOfOneNft.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Everything that should work worked, and everything that should fail failed.
    function invariant_EveryOperationEndedAsTheBooksExpected() public view {
        if (handler.violationCount() != 0) revert(handler.violations(0));
    }

    /// @dev No contract holds money or NFTs, and every unit of money is where the books say: each wallet has what
    /// it must have, and each treasury has what came in while it was the one in force.
    function invariant_MoneyIsWhereTheBooksSay() public view {
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(usdt.balanceOf(address(venta)), 0);
        assertEq(usdt.balanceOf(address(mercado)), 0);
        assertEq(prenda.balanceOf(address(venta)), 0);
        assertEq(prenda.balanceOf(address(mercado)), 0);
        assertEq(prenda.balanceOf(address(otherMarket)), 0);

        assertEq(usdt.balanceOf(treasury), handler.treasuryIncomeOf(treasury));
        assertEq(usdt.balanceOf(secondTreasury), handler.treasuryIncomeOf(secondTreasury));
        assertEq(usdt.balanceOf(treasury) + usdt.balanceOf(secondTreasury), handler.treasuryIncome());
        uint256 heldByWallets;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(usdt.balanceOf(actor), handler.expectedBalance(actor));
            heldByWallets += usdt.balanceOf(actor);
        }
        assertEq(usdt.totalSupply(), handler.treasuryIncome() + heldByWallets);
    }

    /// @dev Every garment ever put on sale: its drop, who holds its NFT, whether it was sold, how often it changed
    /// hands, its approval, how often that approval was taken back from the market and its offer on the market.
    function invariant_EveryGarmentMatchesTheBooks() public view {
        uint256 count = handler.itemCount();
        uint256 alive;
        for (uint256 tokenId = 1; tokenId <= count; tokenId++) {
            ArchivoHandler.ItemBook memory item = handler.itemBook(tokenId);
            (uint32 dropId, uint80 price, bool sold, bytes32 contentHash) = venta.itemOf(tokenId);
            assertEq(dropId, item.dropId);
            assertEq(price, item.price);
            assertEq(sold, item.sold);
            assertEq(contentHash, handler.fingerprint(tokenId, item.dropId));
            assertEq(prenda.isTokenIdUsed(tokenId), item.sold);
            assertEq(prenda.transferCountOf(tokenId), item.moves);
            assertEq(prenda.tokenApprovalsRevoked(tokenId, address(mercado)), handler.revokedForNftBook(tokenId));

            if (item.sold && !item.burned) {
                alive += 1;
                assertEq(prenda.ownerOf(tokenId), item.holder);
                assertEq(prenda.contentHashOf(tokenId), contentHash);
                assertEq(prenda.getApproved(tokenId), item.approved);
                (uint48 freeUntil, , ) = prenda.storageTermsOf(tokenId);
                assertEq(freeUntil, item.freeUntil);
            } else {
                assertEq(item.approved, address(0));
                try prenda.ownerOf(tokenId) returns (address) {
                    revert("an NFT that was not sold, or was burned, has a holder");
                } catch {}
            }

            ArchivoHandler.ListingBook memory listing = handler.listingBook(tokenId);
            Mercado.Listing memory recorded = mercado.listingOf(tokenId);
            assertEq(recorded.seller, listing.exists ? listing.seller : address(0));
            assertEq(recorded.price, listing.price);
            assertEq(recorded.expiresAt, listing.expiresAt);
            assertEq(recorded.transferCount, listing.moves);
            assertEq(recorded.approvalsForAllRevoked, listing.revokedForAll);
            assertEq(recorded.tokenApprovalsRevoked, listing.revokedForNft);
        }
        assertEq(alive, handler.liveCount());

        uint256 held;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += prenda.balanceOf(handler.actors(i));
        }
        assertEq(held, alive);
    }

    /// @dev What the books kept on the side instead of reading it from the contracts: drops closed, approvals for
    /// the market, approvals for all taken back, the pause and the treasury in force.
    function invariant_SwitchesAndApprovalsMatchTheBooks() public view {
        assertEq(prenda.paused(), handler.pausedBook());
        assertEq(prenda.treasury(), handler.treasuryBook());
        assertEq(venta.dropCount(), handler.dropCount());
        for (uint32 dropId = 1; dropId <= handler.dropCount(); dropId++) {
            assertEq(venta.dropOf(dropId).closed, handler.dropBook(dropId).closed);
        }
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(prenda.isApprovedForAll(actor, address(mercado)), handler.approvesMarket(actor));
            assertEq(prenda.approvalsForAllRevoked(actor, address(mercado)), handler.revokedForAllBook(actor));
        }
    }

    /**
     * @dev The same handler driven by fixed pseudo-random sequences, so that every run is the same and the tests
     * can check that every kind of operation really happened. There are several short walks instead of a long
     * one: a failing walk prints every call it made, and a long one runs out of memory before it can report.
     */
    function test_FixedRandomWalkA() public {
        _walk("archivo a");
    }

    function test_FixedRandomWalkB() public {
        _walk("archivo b");
    }

    function test_FixedRandomWalkC() public {
        _walk("archivo c");
    }

    function test_FixedRandomWalkD() public {
        _walk("archivo d");
    }

    function test_FixedRandomWalkE() public {
        _walk("archivo e");
    }

    function _walk(string memory name) internal {
        uint256 steps = 800;
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(name, i)));
            uint256 a = uint256(keccak256(abi.encode(r, uint256(1))));
            uint256 b = uint256(keccak256(abi.encode(r, uint256(2))));
            uint256 c = uint256(keccak256(abi.encode(r, uint256(3))));
            uint256 kind = r % 100;

            if (kind < 7) {
                handler.createDrop(a, uint80(b), c % 2 == 0, uint32(a >> 96), uint80(b >> 96), uint80(c >> 96));
                // Half of the new drops are open right away, so that the purchases that follow find them on sale,
                // and a few are closed before they open.
                if (c % 16 < 8) handler.waitForTheLastDropToOpen();
                else if (c % 16 < 10) handler.closeDrop(0, b % 2 == 0);
            } else if (kind < 9) handler.closeDrop(a, b % 2 == 0);
            else if (kind < 12) {
                handler.createDropWithAUsedNumber(a, uint80(b), c % 2 == 0);
                if (c % 4 < 2) handler.waitForTheLastDropToOpen();
            } else if (kind < 15) handler.waitForTheLastDropToOpen();
            else if (kind < 36) handler.buyFirstSale(a, b, c);
            else if (kind < 39) handler.approveMarket(a, b % 5 != 0);
            else if (kind < 42) handler.approveMarketForOneNft(a, b);
            else if (kind < 52) {
                handler.list(a, uint80(b), uint48(c), c % 6 != 0, b >> 8);
                // Now and then somebody takes the offer that was just made, sometimes after the seller took the
                // approval for all back and gave it again.
                if (c % 8 < 3) handler.buyOnMarket(0, b >> 16, (c << 1) | 1);
                else if (c % 8 < 5) {
                    handler.takeApprovalBackAndGiveItAgain(0, 0);
                    handler.buyOnMarket(0, b >> 16, (c << 1) | 1);
                }
            } else if (kind < 56) {
                // An offer under the approval of one NFT only. Sometimes somebody takes it right away, and
                // sometimes the seller first takes that approval back and gives it again.
                handler.offerUnderTheApprovalOfOneNft(a, uint80(b), uint48(c));
                if (c % 8 < 4) handler.takeApprovalBackAndGiveItAgain(0, 1 + (c >> 8) % 2);
                if (c % 8 < 6) handler.buyOnMarket(0, b >> 16, (c << 1) | 1);
            } else if (kind < 58) handler.cancelListing(a, b % 3 != 0, c);
            else if (kind < 71) handler.buyOnMarket(a, b, c);
            else if (kind < 76) {
                // The NFT moves outside the market and right away somebody tries to take the offer left behind.
                handler.moveOutside(a, b, c % 2 == 0);
                handler.buyOnMarket(a, b >> 16, (c << 1) | 1);
            } else if (kind < 79) {
                // The same with an approval taken back and given again.
                handler.takeApprovalBackAndGiveItAgain(a, b >> 32);
                handler.buyOnMarket(a, b >> 16, (c << 1) | 1);
            } else if (kind < 85) handler.claim(a);
            else if (kind < 88) handler.tryWhatMustFail(a, b, c);
            else if (kind < 90) handler.setPaused(a % 4 == 0);
            else if (kind < 92) handler.changeTreasury(a);
            else handler.letTimePass(uint32(a), b % 5 == 0);

            if (i % 100 == 0) _checkEverything();
        }
        _checkEverything();

        // Each walk must really have gone through every kind of operation, including the ones that must fail.
        assertGt(handler.dropCount(), 40);
        assertGt(handler.dropsClosedBeforeOpening(), 0);
        assertGt(handler.dropsClosedWhileOpen(), 3);
        assertGt(handler.garmentsRelisted(), 1);
        assertGt(handler.refusedRelistings(), 5);
        assertGt(handler.earlyPurchases(), 3);
        assertGt(handler.publicPurchases(), 10);
        assertGt(handler.refusedPurchases(), 50);
        assertGt(handler.purchasesRefusedForTheDrop(), 0);
        assertGt(handler.offersMade(), 15);
        assertGt(handler.resales(), 7);
        assertGt(handler.refusedResales(), 80);
        assertGt(handler.resalesUnderOneNftApproval(), 1);
        assertGt(handler.staleOffersRefused(), 3);
        assertGt(handler.offersRefusedForAllTakenBack(), 2);
        assertGt(handler.offersRefusedForNftTakenBack(), 3);
        assertGt(handler.nftApprovalsCleared(), 2);
        assertGt(handler.nftApprovalsReplaced(), 1);
        assertGt(handler.movesOutside(), 7);
        assertGt(handler.paidClaims(), 0);
        assertGt(handler.freeClaims(), 5);
    }

    function _checkEverything() internal view {
        invariant_EveryOperationEndedAsTheBooksExpected();
        invariant_MoneyIsWhereTheBooksSay();
        invariant_EveryGarmentMatchesTheBooks();
        invariant_SwitchesAndApprovalsMatchTheBooks();
    }
}
