// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Prenda} from "./Prenda.sol";

/**
 * @title Mercado
 * @notice Resale of the NFTs of Allka Archivo between users. The holder of an NFT offers it at a price; whoever
 * pays that price gets the NFT. The payment is split on the spot and goes straight from the buyer to the seller
 * and to the treasury: this contract never holds money and never holds NFTs.
 *
 * The NFT stays in the wallet of its holder until it is sold. To sell, the holder first approves this contract in
 * {Prenda}; this contract can only move an NFT whose holder approved it, and it only does so when a buyer pays the
 * price the holder asked.
 *
 * An offer stops being valid when its time runs out, when the NFT changes hands, when the seller takes back from
 * this contract the approval for all their NFTs, or when the seller takes back from it the approval of that NFT.
 * An offer that stopped being valid never comes back: the seller has to make a new one.
 *
 * Nobody administers this contract. The fee is a constant, so it can never be raised. The treasury, the payment
 * token and the pause are those of {Prenda}.
 */
contract Mercado {
    using SafeERC20 for IERC20;

    /**
     * @notice An offer to sell an NFT.
     * @param seller Who made the offer. The zero address if there is none.
     * @param expiresAt Last moment at which the offer can be taken.
     * @param transferCount How many times the NFT had changed hands when the offer was made. If the NFT changes
     * hands again, the offer stops being valid, even if the NFT comes back to the seller.
     * @param price Price in payment token units, fee included.
     * @param approvalsForAllRevoked How many times the seller had taken back from this contract an approval for
     * all their NFTs when the offer was made. If the seller does it again, the offer stops being valid, even if
     * the approval is given again later.
     * @param tokenApprovalsRevoked The same for the approval of this one NFT.
     */
    struct Listing {
        address seller;
        uint48 expiresAt;
        uint32 transferCount;
        uint80 price;
        uint64 approvalsForAllRevoked;
        uint64 tokenApprovalsRevoked;
    }

    /// @notice Share of every sale that goes to the treasury, in hundredths of a percent: 200 is 2%.
    uint256 public constant FEE_BPS = 200;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Longest time an offer can stay open. Old offers must not stay around for ever.
    uint256 public constant MAX_LISTING_DURATION = 30 days;

    /// @notice The NFT contract. Its treasury receives the fee.
    Prenda public immutable prenda;

    /// @notice Token in which sales are paid. The same one {Prenda} uses for the storage fee.
    IERC20 public immutable paymentToken;

    /// @notice Lowest price an offer can have.
    uint80 public immutable minPrice;

    mapping(uint256 tokenId => Listing) private _listings;

    event Listed(uint256 indexed tokenId, address indexed seller, uint80 price, uint48 expiresAt);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);

    /// @notice `buyer` paid `price`: `fee` went to the treasury and the rest to `seller`.
    event Sold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint80 price, uint256 fee);

    error MinimumPriceTooLow(uint80 minPrice);
    error NotHolder(uint256 tokenId, address caller);
    error MarketNotApproved(uint256 tokenId);
    error PriceBelowMinimum(uint80 price, uint80 minimumAllowed);
    error InvalidExpiry(uint48 expiresAt, uint256 latestAllowed);
    error NotListed(uint256 tokenId);
    error NotSeller(uint256 tokenId, address caller);
    error ListingExpired(uint256 tokenId, uint48 expiresAt);
    error PriceNotAsExpected(uint256 tokenId, uint80 price, uint256 expectedPrice);
    error ListingNoLongerValid(uint256 tokenId);

    /**
     * @param prenda_ The NFT contract.
     * @param minPrice_ Lowest price an offer can have. High enough for the fee never to round down to zero.
     */
    constructor(Prenda prenda_, uint80 minPrice_) {
        if (uint256(minPrice_) * FEE_BPS < BPS_DENOMINATOR) revert MinimumPriceTooLow(minPrice_);
        prenda = prenda_;
        paymentToken = prenda_.paymentToken();
        minPrice = minPrice_;
    }

    /**
     * @notice Offers an NFT for sale, or changes the offer of an NFT already on sale. Only its holder can do it,
     * and only after approving this contract in {Prenda}. A new offer replaces any previous one for the same NFT.
     * @param tokenId The NFT.
     * @param price What the buyer pays, in payment token units. The seller receives it minus the 2% fee.
     * @param expiresAt Last moment at which the offer can be taken. In the future, no later than
     * {MAX_LISTING_DURATION} from now.
     */
    function list(uint256 tokenId, uint80 price, uint48 expiresAt) external {
        address seller = msg.sender;
        if (prenda.ownerOf(tokenId) != seller) revert NotHolder(tokenId, seller);
        if (!prenda.isApprovedForAll(seller, address(this)) && prenda.getApproved(tokenId) != address(this)) {
            revert MarketNotApproved(tokenId);
        }
        if (price < minPrice) revert PriceBelowMinimum(price, minPrice);
        uint256 latestAllowed = block.timestamp + MAX_LISTING_DURATION;
        if (expiresAt <= block.timestamp || expiresAt > latestAllowed) revert InvalidExpiry(expiresAt, latestAllowed);

        _listings[tokenId] = Listing({
            seller: seller,
            expiresAt: expiresAt,
            transferCount: prenda.transferCountOf(tokenId),
            price: price,
            approvalsForAllRevoked: prenda.approvalsForAllRevoked(seller, address(this)),
            tokenApprovalsRevoked: prenda.tokenApprovalsRevoked(tokenId, address(this))
        });
        emit Listed(tokenId, seller, price, expiresAt);
    }

    /// @notice Withdraws an offer. Only whoever made it can do it, at any time.
    function cancel(uint256 tokenId) external {
        address seller = _listings[tokenId].seller;
        if (seller == address(0)) revert NotListed(tokenId);
        if (seller != msg.sender) revert NotSeller(tokenId, msg.sender);

        delete _listings[tokenId];
        emit ListingCancelled(tokenId, seller);
    }

    /**
     * @notice Buys an NFT that is on sale. The caller must have approved this contract to take the price in
     * payment token. The price goes from the caller to the seller, minus the fee, which goes to the treasury.
     * @param tokenId The NFT.
     * @param expectedPrice The price the buyer saw. The purchase fails if the seller changed it.
     */
    function buy(uint256 tokenId, uint256 expectedPrice) external {
        Listing memory listing = _listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (block.timestamp > listing.expiresAt) revert ListingExpired(tokenId, listing.expiresAt);
        if (listing.price != expectedPrice) revert PriceNotAsExpected(tokenId, listing.price, expectedPrice);
        // The offer is only good if the NFT is still in the hands it was in when the offer was made, and the
        // seller has not taken back from this contract, since then, the approval for all or the one of this NFT.
        if (
            prenda.transferCountOf(tokenId) != listing.transferCount ||
            prenda.ownerOf(tokenId) != listing.seller ||
            prenda.approvalsForAllRevoked(listing.seller, address(this)) != listing.approvalsForAllRevoked ||
            prenda.tokenApprovalsRevoked(tokenId, address(this)) != listing.tokenApprovalsRevoked
        ) revert ListingNoLongerValid(tokenId);

        address buyer = msg.sender;
        uint256 fee = (uint256(listing.price) * FEE_BPS) / BPS_DENOMINATOR;

        delete _listings[tokenId];
        emit Sold(tokenId, listing.seller, buyer, listing.price, fee);

        // Money first, NFT second, all in this transaction: if anything fails, nothing happened.
        paymentToken.safeTransferFrom(buyer, listing.seller, listing.price - fee);
        paymentToken.safeTransferFrom(buyer, prenda.treasury(), fee);
        prenda.transferFrom(listing.seller, buyer, tokenId);
    }

    /// @notice The offer recorded for an NFT. All zero if there is none. It may no longer be valid: see {buy}.
    function listingOf(uint256 tokenId) external view returns (Listing memory) {
        return _listings[tokenId];
    }
}
