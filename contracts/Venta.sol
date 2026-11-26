// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Prenda} from "./Prenda.sol";

/**
 * @title Venta
 * @notice First sale of the garments of Allka Archivo. Garments go on sale in drops. Each garment has its own
 * number, which is the id of its NFT, and its own price. Buying sends the price straight from the buyer to the
 * treasury and creates the NFT for the buyer in the same transaction: this contract never holds money.
 *
 * A drop cannot be changed once it is created. It opens no sooner than {openingDelay} after its creation, so that
 * a mistake or an abuse can be noticed in time, and until it opens it can be cancelled.
 *
 * A drop can open first for the wallets of a snapshot (the holders of $FGM at a moment chosen before the drop).
 * During that early window each of those wallets can buy one garment. After it, anyone can buy.
 *
 * Who does what:
 * - The operator creates and cancels drops. It cannot decide where the money goes.
 * - The administration is the administration of {Prenda}. It names the operator and can cancel a drop too.
 * - The treasury, the payment token and the pause are those of {Prenda}.
 */
contract Venta {
    using SafeERC20 for IERC20;

    /// @notice A garment of a new drop, as the operator gives it.
    /// @param tokenId Number of the garment and id of its NFT.
    /// @param price Price in payment token units.
    /// @param contentHash Fingerprint of the data of the NFT (photos, size, description).
    struct NewItem {
        uint256 tokenId;
        uint80 price;
        bytes32 contentHash;
    }

    /**
     * @notice A drop.
     * @param earlyStart When the wallets of the snapshot can start buying. Equal to `publicStart` if the drop has
     * no early window.
     * @param publicStart When anyone can start buying.
     * @param freePeriod Seconds of free storage for each garment, counted from its sale.
     * @param feePerPeriod Storage fee added for every full 30 days after the free period.
     * @param cancelled True if the drop was cancelled before it opened.
     * @param maxFee Ceiling of the storage fee.
     * @param earlyRoot Merkle root of the snapshot. Zero if the drop has no early window.
     */
    struct Drop {
        uint48 earlyStart;
        uint48 publicStart;
        uint32 freePeriod;
        uint80 feePerPeriod;
        bool cancelled;
        uint80 maxFee;
        bytes32 earlyRoot;
    }

    /// @dev What is recorded for a garment that was put on sale. `dropId` is zero if it never was.
    struct Item {
        uint32 dropId;
        uint80 price;
        bool sold;
    }

    /// @notice The NFT contract. Its treasury receives the money and its administration is this contract's.
    Prenda public immutable prenda;

    /// @notice Token in which garments are paid. The same one {Prenda} uses for the storage fee.
    IERC20 public immutable paymentToken;

    /// @notice Shortest time between the creation of a drop and its opening.
    uint48 public immutable openingDelay;

    /// @notice Lowest price a garment can have. A guard against a price typed with the wrong number of zeros.
    uint80 public immutable minPrice;

    /// @notice Highest ceiling a drop can set for the storage fee.
    uint80 public immutable maxStorageFee;

    /// @notice Account that creates and cancels drops.
    address public operator;

    /// @notice Number of drops ever created. Drop ids go from 1 to this number.
    uint32 public dropCount;

    /// @notice Whether `account` already bought its garment in the early window of a drop.
    mapping(uint32 dropId => mapping(address account => bool)) public boughtEarly;

    mapping(uint32 dropId => Drop) private _drops;
    mapping(uint256 tokenId => Item) private _items;
    mapping(uint256 tokenId => bytes32) private _contentHashes;

    event DropCreated(
        uint32 indexed dropId,
        uint48 earlyStart,
        uint48 publicStart,
        bytes32 earlyRoot,
        uint32 freePeriod,
        uint80 feePerPeriod,
        uint80 maxFee
    );
    event ItemAdded(uint32 indexed dropId, uint256 indexed tokenId, uint80 price, bytes32 contentHash);
    event DropCancelled(uint32 indexed dropId);

    /// @notice `buyer` paid `price` for a garment. `early` tells whether it was during the early window.
    event Purchased(uint32 indexed dropId, uint256 indexed tokenId, address indexed buyer, uint80 price, bool early);

    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    error ZeroMinimumPrice();
    error NotOperator(address caller);
    error NotAdmin(address caller);
    error NotOperatorOrAdmin(address caller);
    error EmptyDrop();
    error OpensTooSoon(uint48 earlyStart, uint256 earliestAllowed);
    error InvalidDates(uint48 earlyStart, uint48 publicStart);
    error InvalidStorageTerms(uint80 feePerPeriod, uint80 maxFee);
    error StorageFeeAboveMaximum(uint80 maxFee, uint80 maximumAllowed);
    error PriceBelowMinimum(uint256 tokenId, uint80 price, uint80 minimumAllowed);
    error EmptyContentHash(uint256 tokenId);
    error TokenIdNotAvailable(uint256 tokenId);
    error UnknownDrop(uint32 dropId);
    error DropAlreadyCancelled(uint32 dropId);
    error DropAlreadyOpen(uint32 dropId);
    error NotOnSale(uint256 tokenId);
    error AlreadySold(uint256 tokenId);
    error NotOpenYet(uint256 tokenId, uint48 opensAt);
    error PriceNotAsExpected(uint256 tokenId, uint80 price, uint256 expectedPrice);
    error NotInSnapshot(address buyer);
    error EarlyPurchaseAlreadyMade(address buyer);

    /**
     * @param prenda_ The NFT contract.
     * @param operator_ Account that creates and cancels drops.
     * @param openingDelay_ Shortest time between creating a drop and its opening. 24 hours on mainnet; shorter
     * only on test networks.
     * @param minPrice_ Lowest price a garment can have. Not zero.
     * @param maxStorageFee_ Highest ceiling a drop can set for the storage fee.
     */
    constructor(Prenda prenda_, address operator_, uint48 openingDelay_, uint80 minPrice_, uint80 maxStorageFee_) {
        if (minPrice_ == 0) revert ZeroMinimumPrice();
        prenda = prenda_;
        paymentToken = prenda_.paymentToken();
        openingDelay = openingDelay_;
        minPrice = minPrice_;
        maxStorageFee = maxStorageFee_;
        _setOperator(operator_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Buyers
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Buys a garment: pays its price to the treasury and receives its NFT. The caller must have approved
     * this contract to take the price in payment token.
     * @param tokenId Number of the garment.
     * @param expectedPrice The price the buyer saw. The purchase fails if it is not the price of the garment.
     * @param earlyProof Merkle proof that the caller is in the snapshot of the drop. Only used during the early
     * window; empty otherwise.
     */
    function buy(uint256 tokenId, uint256 expectedPrice, bytes32[] calldata earlyProof) external {
        Item memory item = _items[tokenId];
        Drop storage drop = _drops[item.dropId];
        if (item.dropId == 0 || drop.cancelled) revert NotOnSale(tokenId);
        if (item.sold) revert AlreadySold(tokenId);
        if (block.timestamp < drop.earlyStart) revert NotOpenYet(tokenId, drop.earlyStart);
        if (item.price != expectedPrice) revert PriceNotAsExpected(tokenId, item.price, expectedPrice);

        address buyer = msg.sender;
        bool early = block.timestamp < drop.publicStart;
        if (early) {
            if (boughtEarly[item.dropId][buyer]) revert EarlyPurchaseAlreadyMade(buyer);
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(buyer))));
            if (!MerkleProof.verifyCalldata(earlyProof, drop.earlyRoot, leaf)) revert NotInSnapshot(buyer);
            boughtEarly[item.dropId][buyer] = true;
        }

        _items[tokenId].sold = true;
        emit Purchased(item.dropId, tokenId, buyer, item.price, early);

        // Money first, NFT second, both in this transaction: if either fails, nothing happened.
        paymentToken.safeTransferFrom(buyer, prenda.treasury(), item.price);
        prenda.mint(
            buyer,
            tokenId,
            Prenda.StorageTerms({
                freePeriod: drop.freePeriod,
                feePerPeriod: drop.feePerPeriod,
                maxFee: drop.maxFee
            }),
            _contentHashes[tokenId]
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Creates a drop. Nothing in it can be changed afterwards; before it opens it can be cancelled.
     * @param earlyStart When the wallets of the snapshot can start buying. At least {openingDelay} from now.
     * @param publicStart When anyone can start buying. Later than `earlyStart` if there is a snapshot, equal to it
     * if there is none.
     * @param earlyRoot Merkle root of the snapshot, built from the addresses with the standard double hash of
     * OpenZeppelin's merkle-tree library. Zero for a drop without early window.
     * @param storageTerms Storage rules of every garment of the drop.
     * @param items Garments of the drop. Their numbers must never have been used and must not be in another drop.
     */
    function createDrop(
        uint48 earlyStart,
        uint48 publicStart,
        bytes32 earlyRoot,
        Prenda.StorageTerms calldata storageTerms,
        NewItem[] calldata items
    ) external returns (uint32 dropId) {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        if (items.length == 0) revert EmptyDrop();
        uint256 earliestAllowed = block.timestamp + openingDelay;
        if (earlyStart < earliestAllowed) revert OpensTooSoon(earlyStart, earliestAllowed);
        if (earlyRoot == bytes32(0) ? publicStart != earlyStart : publicStart <= earlyStart) {
            revert InvalidDates(earlyStart, publicStart);
        }
        if (
            storageTerms.feePerPeriod == 0 ? storageTerms.maxFee != 0 : storageTerms.maxFee < storageTerms.feePerPeriod
        ) revert InvalidStorageTerms(storageTerms.feePerPeriod, storageTerms.maxFee);
        if (storageTerms.maxFee > maxStorageFee) revert StorageFeeAboveMaximum(storageTerms.maxFee, maxStorageFee);

        dropId = ++dropCount;
        _drops[dropId] = Drop({
            earlyStart: earlyStart,
            publicStart: publicStart,
            freePeriod: storageTerms.freePeriod,
            feePerPeriod: storageTerms.feePerPeriod,
            cancelled: false,
            maxFee: storageTerms.maxFee,
            earlyRoot: earlyRoot
        });
        emit DropCreated(
            dropId,
            earlyStart,
            publicStart,
            earlyRoot,
            storageTerms.freePeriod,
            storageTerms.feePerPeriod,
            storageTerms.maxFee
        );

        for (uint256 i = 0; i < items.length; ++i) {
            NewItem calldata item = items[i];
            if (item.price < minPrice) revert PriceBelowMinimum(item.tokenId, item.price, minPrice);
            if (item.contentHash == bytes32(0)) revert EmptyContentHash(item.tokenId);
            if (!_isAvailable(item.tokenId)) revert TokenIdNotAvailable(item.tokenId);

            _items[item.tokenId] = Item({dropId: dropId, price: item.price, sold: false});
            _contentHashes[item.tokenId] = item.contentHash;
            emit ItemAdded(dropId, item.tokenId, item.price, item.contentHash);
        }
    }

    /// @notice Cancels a drop that has not opened yet. Its garments can go into a new drop.
    function cancelDrop(uint32 dropId) external {
        if (msg.sender != operator && msg.sender != prenda.owner()) revert NotOperatorOrAdmin(msg.sender);
        if (dropId == 0 || dropId > dropCount) revert UnknownDrop(dropId);
        Drop storage drop = _drops[dropId];
        if (drop.cancelled) revert DropAlreadyCancelled(dropId);
        if (block.timestamp >= drop.earlyStart) revert DropAlreadyOpen(dropId);

        drop.cancelled = true;
        emit DropCancelled(dropId);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Names the account that creates and cancels drops. The zero address leaves nobody in that role.
    function setOperator(address newOperator) external {
        if (msg.sender != prenda.owner()) revert NotAdmin(msg.sender);
        _setOperator(newOperator);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The drop with that id. All zero if it does not exist.
    function dropOf(uint32 dropId) external view returns (Drop memory) {
        return _drops[dropId];
    }

    /**
     * @notice What is recorded for a garment: the last drop it was put in (zero if none), its price there, whether
     * it was sold and the fingerprint of its data.
     */
    function itemOf(
        uint256 tokenId
    ) external view returns (uint32 dropId, uint80 price, bool sold, bytes32 contentHash) {
        Item storage item = _items[tokenId];
        return (item.dropId, item.price, item.sold, _contentHashes[tokenId]);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------------------

    /// @dev A number can go on sale if it is not in a drop that is still valid and no NFT ever had it.
    function _isAvailable(uint256 tokenId) private view returns (bool) {
        uint32 current = _items[tokenId].dropId;
        return (current == 0 || _drops[current].cancelled) && !prenda.isTokenIdUsed(tokenId);
    }

    function _setOperator(address newOperator) private {
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }
}
