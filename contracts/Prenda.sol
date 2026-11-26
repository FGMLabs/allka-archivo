// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice What a sale or market module must answer for {Prenda} to accept it.
interface IPrendaModule {
    /// @notice The NFT contract this module was built for.
    function prenda() external view returns (address);
}

/**
 * @title Prenda
 * @notice One NFT for each physical allka garment. Whoever holds the NFT can claim the garment: claiming burns the
 * NFT and, once the free storage period is over, pays the storage fee.
 *
 * This is the permanent contract of Allka Archivo. Sales and resale live in separate modules that the
 * administration can add or retire:
 *
 * - Minters (the `Venta` modules) create the NFTs. A token id can be created only once, ever.
 * - Markets (the `Mercado` modules) are the only ones that can move an NFT between holders while transfers are
 *   closed. A market can only move an NFT whose holder approved that market: being authorized here gives a market
 *   no power over anybody's NFT.
 *
 * Approvals are stricter than in a plain ERC-721, so that the rules above do not depend on how any market is
 * written: only the holder can approve somebody (an approved operator cannot pass its permission on), only an
 * account that may move tokens can be approved, and a market that was disabled loses every approval it had.
 *
 * What the administration can never do: move or burn somebody else's NFT, raise a storage fee, or create again a
 * token id that was already used.
 *
 * In this contract "holder" is whoever owns an NFT and "owner" is the administration account (see {Ownable2Step}).
 */
contract Prenda is ERC721, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Life of a market. It only moves forward: None, then Authorized, then Disabled for good.
    enum MarketStatus {
        None,
        Authorized,
        Disabled
    }

    /**
     * @notice Storage rules that a minter fixes for a garment at the moment it is sold.
     * @param freePeriod Seconds of free storage, counted from the sale.
     * @param feePerPeriod Amount of payment token added for every full {STORAGE_PERIOD} after the free period.
     * @param maxFee Ceiling of the storage fee. Zero if and only if `feePerPeriod` is zero.
     */
    struct StorageTerms {
        uint32 freePeriod;
        uint80 feePerPeriod;
        uint80 maxFee;
    }

    /// @dev Everything the contract records about a token id. Fits in one storage slot. Kept after the burn.
    struct TokenRecord {
        uint48 freeUntil;
        uint80 feePerPeriod;
        uint80 maxFee;
        uint32 transferCount;
        bool used;
    }

    /// @notice Length of a storage instalment. One instalment is added for every full period after the free one.
    uint256 public constant STORAGE_PERIOD = 30 days;

    /// @notice Token in which the storage fee is paid. It can never be changed.
    IERC20 public immutable paymentToken;

    /// @notice Account that receives the money. The sale and resale modules read it from here.
    address public treasury;

    /// @notice False while NFTs can only move through an authorized market. Once true it stays true.
    bool public transfersOpen;

    /// @notice Modules that are allowed to create NFTs.
    mapping(address account => bool) public isMinter;

    /// @notice Status of every market the administration ever registered.
    mapping(address account => MarketStatus) public marketStatus;

    mapping(uint256 tokenId => TokenRecord) private _records;
    mapping(uint256 tokenId => bytes32) private _contentHashes;
    string private _baseTokenURI;

    /// @notice A garment was sold for the first time and its NFT was created by the module `minter`.
    event Minted(
        uint256 indexed tokenId,
        address indexed to,
        address indexed minter,
        uint48 freeUntil,
        uint80 feePerPeriod,
        uint80 maxFee,
        bytes32 contentHash
    );

    /// @notice `claimer` burned the NFT to receive the physical garment and paid `storageFee`.
    event Claimed(uint256 indexed tokenId, address indexed claimer, uint256 storageFee);

    /// @notice The administration gave a garment more free storage.
    event FreeStorageExtended(uint256 indexed tokenId, uint48 previousFreeUntil, uint48 newFreeUntil);

    event MinterSet(address indexed minter, bool allowed);
    event MarketAuthorized(address indexed market);
    event MarketDisabled(address indexed market);
    event TransfersOpened();
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);
    event BaseURIChanged(string newBaseURI);

    error NotAContract(address account);
    error NotAModule(address account);
    error InvalidTreasury(address account);
    error NotMinter(address caller);
    error TokenIdAlreadyUsed(uint256 tokenId);
    error EmptyContentHash();
    error InvalidStorageTerms(uint80 feePerPeriod, uint80 maxFee);
    error NotTokenHolder(uint256 tokenId, address caller);
    error StorageFeeAboveAccepted(uint256 tokenId, uint256 storageFee, uint256 maxFeeAccepted);
    error TransferNotAllowed(address executor);
    error ApprovalNotAllowed(address operator);
    error MarketAlreadyRegistered(address market);
    error MarketNotAuthorized(address market);
    error TransfersAlreadyOpen();
    error FreeStorageNotExtended(uint256 tokenId, uint48 currentFreeUntil, uint48 requestedFreeUntil);
    error OwnershipCannotBeRenounced();

    /**
     * @param name_ Name of the collection.
     * @param symbol_ Symbol of the collection.
     * @param paymentToken_ Token used to pay the storage fee (USDT0 on Conflux eSpace).
     * @param treasury_ Account that receives the money.
     * @param admin_ Administration account. It is the only one that can use the switches of this contract.
     * @param baseURI_ Address where the data of each NFT is served; the token id is appended to it.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        IERC20 paymentToken_,
        address treasury_,
        address admin_,
        string memory baseURI_
    ) ERC721(name_, symbol_) Ownable(admin_) {
        if (address(paymentToken_).code.length == 0) revert NotAContract(address(paymentToken_));
        paymentToken = paymentToken_;
        _setTreasury(treasury_);
        _setBaseURI(baseURI_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Holders
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Claims the physical garment. Burns the NFT and, if storage is no longer free, sends the storage fee
     * from the caller to the treasury. Only the holder can claim. Claims keep working while the contract is paused.
     *
     * When the fee is zero the payment token is not called at all, so a free claim cannot be blocked by it.
     *
     * @param tokenId The NFT of the garment.
     * @param maxFeeAccepted The most the caller accepts to pay. The claim fails if the fee is higher, for example
     * because a new instalment was added between signing and confirmation.
     */
    function claim(uint256 tokenId, uint256 maxFeeAccepted) external {
        address claimer = _msgSender();
        if (_requireOwned(tokenId) != claimer) revert NotTokenHolder(tokenId, claimer);

        uint256 fee = _storageFee(_records[tokenId]);
        if (fee > maxFeeAccepted) revert StorageFeeAboveAccepted(tokenId, fee, maxFeeAccepted);

        _burn(tokenId);
        emit Claimed(tokenId, claimer, fee);

        if (fee != 0) {
            paymentToken.safeTransferFrom(claimer, treasury, fee);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Minters
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Creates the NFT of a garment for its first buyer. Only minter modules can call it, and only while the
     * contract is not paused. Collecting the price is the job of the module.
     * @param to First holder. Not this contract.
     * @param tokenId Number of the garment. It must never have been used, not even by an NFT already burned.
     * @param terms Storage rules of the garment. The free period starts now.
     * @param contentHash_ Fingerprint of the data of the NFT, so that later changes can be detected. Not zero.
     */
    function mint(
        address to,
        uint256 tokenId,
        StorageTerms calldata terms,
        bytes32 contentHash_
    ) external whenNotPaused {
        address minter = _msgSender();
        if (!isMinter[minter]) revert NotMinter(minter);
        if (contentHash_ == bytes32(0)) revert EmptyContentHash();
        if (terms.feePerPeriod == 0 ? terms.maxFee != 0 : terms.maxFee < terms.feePerPeriod) {
            revert InvalidStorageTerms(terms.feePerPeriod, terms.maxFee);
        }
        if (_records[tokenId].used) revert TokenIdAlreadyUsed(tokenId);

        uint48 freeUntil = SafeCast.toUint48(block.timestamp + terms.freePeriod);
        _records[tokenId] = TokenRecord({
            freeUntil: freeUntil,
            feePerPeriod: terms.feePerPeriod,
            maxFee: terms.maxFee,
            transferCount: 0,
            used: true
        });
        _contentHashes[tokenId] = contentHash_;

        // `_mint` and not `_safeMint`: the module must not hand control to the buyer in the middle of a sale.
        _mint(to, tokenId);
        emit Minted(tokenId, to, minter, freeUntil, terms.feePerPeriod, terms.maxFee, contentHash_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Administration
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Allows or stops a module from creating NFTs. Only a module built for this contract can be allowed.
    function setMinter(address minter, bool allowed) external onlyOwner {
        if (allowed) _requireModule(minter);
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    /**
     * @notice Registers a market. From then on it can move the NFTs whose holders approve it, and no others.
     * Only a module built for this contract can be registered, and only once.
     */
    function authorizeMarket(address market) external onlyOwner {
        _requireModule(market);
        if (marketStatus[market] != MarketStatus.None) revert MarketAlreadyRegistered(market);
        marketStatus[market] = MarketStatus.Authorized;
        emit MarketAuthorized(market);
    }

    /**
     * @notice Turns a market off for good. It can never move an NFT again, not even after transfers are opened,
     * and the approvals holders gave it stop counting.
     */
    function disableMarket(address market) external onlyOwner {
        if (marketStatus[market] != MarketStatus.Authorized) revert MarketNotAuthorized(market);
        marketStatus[market] = MarketStatus.Disabled;
        emit MarketDisabled(market);
    }

    /// @notice Lets holders move their NFTs freely, as in any ERC-721. This cannot be undone.
    function openTransfers() external onlyOwner {
        if (transfersOpen) revert TransfersAlreadyOpen();
        transfersOpen = true;
        emit TransfersOpened();
    }

    /// @notice Changes the account that receives the money.
    function setTreasury(address newTreasury) external onlyOwner {
        _setTreasury(newTreasury);
    }

    /**
     * @notice Gives a garment more free storage. This is the only way to change the storage of a garment already
     * sold, and it can only lower what its holder pays: the date can move forward, never back.
     * @param newFreeUntil New end of the free storage, as a Unix timestamp. Later than the current one.
     */
    function extendFreeStorage(uint256 tokenId, uint48 newFreeUntil) external onlyOwner {
        _requireOwned(tokenId);
        uint48 currentFreeUntil = _records[tokenId].freeUntil;
        if (newFreeUntil <= currentFreeUntil) revert FreeStorageNotExtended(tokenId, currentFreeUntil, newFreeUntil);
        _records[tokenId].freeUntil = newFreeUntil;
        emit FreeStorageExtended(tokenId, currentFreeUntil, newFreeUntil);
    }

    /**
     * @notice Changes the address where the data of the NFTs is served. The data itself is sealed by the
     * fingerprint recorded when each NFT was created, see {contentHashOf}.
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _setBaseURI(newBaseURI);
    }

    /// @notice Stops sales and transfers in an emergency. Claims are never stopped.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes sales and transfers.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Always fails: this contract must never be left without administration.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice What claiming this garment costs right now, in payment token units.
    function storageFeeOf(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _storageFee(_records[tokenId]);
    }

    /**
     * @notice Storage rules of a garment. Storage is free until `freeUntil`; after that `feePerPeriod` is added
     * for every full {STORAGE_PERIOD}, up to `maxFee`. All zero for a token id that was never used.
     */
    function storageTermsOf(
        uint256 tokenId
    ) external view returns (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) {
        TokenRecord storage record = _records[tokenId];
        return (record.freeUntil, record.feePerPeriod, record.maxFee);
    }

    /// @notice Fingerprint of the data of the NFT, fixed when it was created. Zero if the id was never used.
    function contentHashOf(uint256 tokenId) external view returns (bytes32) {
        return _contentHashes[tokenId];
    }

    /// @notice How many times the NFT changed hands. Markets use it to discard offers made by a previous holder.
    function transferCountOf(uint256 tokenId) external view returns (uint32) {
        return _records[tokenId].transferCount;
    }

    /// @notice True if the token id was ever created, even if its NFT was burned since.
    function isTokenIdUsed(uint256 tokenId) external view returns (bool) {
        return _records[tokenId].used;
    }

    /**
     * @notice Whether `operator` can move every NFT of `holder`. An approval only counts while its operator may
     * move tokens: a market that was disabled is nobody's operator any more.
     */
    function isApprovedForAll(address holder, address operator) public view override returns (bool) {
        return _mayMoveTokens(operator) && super.isApprovedForAll(holder, operator);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Zero until `freeUntil`; then one instalment per full period, never above the ceiling.
    function _storageFee(TokenRecord memory record) private view returns (uint256) {
        if (block.timestamp <= record.freeUntil) return 0;
        uint256 fee = ((block.timestamp - record.freeUntil) / STORAGE_PERIOD) * record.feePerPeriod;
        return fee < record.maxFee ? fee : record.maxFee;
    }

    /**
     * @dev Whether `account` may be the one that executes a transfer. While transfers are closed, only authorized
     * markets. Once they are open, anyone except a disabled market. This is on top of the ERC-721 rules: the
     * executor still has to be the holder or be approved by the holder.
     */
    function _mayMoveTokens(address account) private view returns (bool) {
        MarketStatus status = marketStatus[account];
        return transfersOpen ? status != MarketStatus.Disabled : status == MarketStatus.Authorized;
    }

    /**
     * @dev A module is a contract that names this contract as its NFT contract. This guards against registering a
     * wrong address by mistake, and it means the administration can only register, and later disable, contracts
     * built for this NFT contract. It does not prove that a module is safe: each module needs its own review.
     */
    function _requireModule(address module) private view {
        (bool success, bytes memory answer) = module.staticcall(abi.encodeCall(IPrendaModule.prenda, ()));
        bytes32 expected = bytes32(uint256(uint160(address(this))));
        if (!success || answer.length != 32 || bytes32(answer) != expected) revert NotAModule(module);
    }

    /// @dev Adds the transfer rules of this contract. Creating and burning an NFT are not transfers.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        // An NFT held by this contract could never be claimed or moved again.
        if (to == address(this)) revert ERC721InvalidReceiver(to);
        if (to != address(0) && _ownerOf(tokenId) != address(0)) {
            _requireNotPaused();
            if (!_mayMoveTokens(auth)) revert TransferNotAllowed(auth);
            _records[tokenId].transferCount += 1;
        }
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Only the holder sets or clears the approval of an NFT, and only an account that may move tokens can be
     * approved. `auth` is zero only when the library clears the approval during a transfer or a burn.
     */
    function _approve(address to, uint256 tokenId, address auth, bool emitEvent) internal override {
        if (auth != address(0) && auth != _requireOwned(tokenId)) revert ERC721InvalidApprover(auth);
        if (to != address(0) && !_mayMoveTokens(to)) revert ApprovalNotAllowed(to);
        super._approve(to, tokenId, auth, emitEvent);
    }

    /// @dev Only an account that may move tokens can be approved. Revoking an approval is always possible.
    function _setApprovalForAll(address holder, address operator, bool approved) internal override {
        if (approved && !_mayMoveTokens(operator)) revert ApprovalNotAllowed(operator);
        super._setApprovalForAll(holder, operator, approved);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _setTreasury(address newTreasury) private {
        if (newTreasury == address(0) || newTreasury == address(this)) revert InvalidTreasury(newTreasury);
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    function _setBaseURI(string memory newBaseURI) private {
        _baseTokenURI = newBaseURI;
        emit BaseURIChanged(newBaseURI);
    }
}
