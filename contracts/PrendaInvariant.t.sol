// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Prenda} from "./Prenda.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

/**
 * @notice Random sequences of everything that can happen to the NFT contract: sales, resales through the market,
 * direct transfer attempts, approvals given and taken back, claims, attempts by the wrong party, storage waivers,
 * pauses, treasury changes, opening transfers and disabling the market. The handler keeps its own books and writes
 * down anything that must never happen; after every step the invariants compare the contract with those books.
 * The books never read the contract to decide what should happen: approvals, approvals taken back, storage dates
 * and fees, the treasury in force, the pause and the two one-way switches are kept on the side.
 *
 * The handler plays the sale module: it is the minter, and it names the NFT contract through `prenda()`.
 */
contract PrendaHandler is Test {
    struct Book {
        bool burned;
        address holder;
        /// The end of free storage fixed at the sale, and the garment's own end after the waivers it got.
        uint48 originalFreeUntil;
        uint48 freeUntil;
        uint80 feePerPeriod;
        uint80 maxFee;
        uint32 moves;
        address approved;
    }

    /// @dev How far ahead of the present a waiver can reach.
    uint256 public constant MAX_WAIVER = 730 days;

    Prenda public immutable prenda;
    TestUSDT0 public immutable usdt;
    OpenMarketMock public immutable market;
    address public immutable admin;
    address public immutable pauser;

    address[] public actors;
    address[2] public treasuries;

    uint256 public minted;
    uint256 public liveCount;
    uint256 public feesPaid;
    mapping(uint256 tokenId => Book) internal _books;

    /// @dev Approvals as the holders gave them, how many approvals for all each holder took back from each
    /// operator, how many times the approval of each NFT was taken back from each operator, the pause and the two
    /// switches that only go one way.
    mapping(address holder => mapping(address operator => bool)) public approvedForAllBook;
    mapping(address holder => mapping(address operator => uint64)) public revokedForAllBook;
    mapping(uint256 tokenId => mapping(address operator => uint64)) public revokedForNftBook;
    bool public pausedBook;
    bool public openBook;
    bool public marketDisabledBook;

    /// @dev The end of free storage given to every garment, the treasury in force and the one proposed.
    uint48 public forAllBook;
    address public treasuryBook;
    address public pendingTreasuryBook;

    /// @dev Things that must never happen. The invariant test requires this list to stay empty.
    string[] public violations;

    /// @dev The last NFT whose approval was given. Approvals aim at it half of the time, so that approvals of one
    /// NFT are replaced and cleared often enough.
    uint256 internal _lastApproved;

    // Counters, so that the fixed walk can check that the interesting paths were really taken.
    uint256 public marketMoves;
    uint256 public directMoves;
    uint256 public paidClaims;
    uint256 public freeClaims;
    uint256 public blockedByPause;
    uint256 public waivers;
    uint256 public waiversForAll;
    uint256 public waiversBeyondTheLimit;
    uint256 public refusedGrants;
    uint256 public approvalsForAllTakenBack;
    uint256 public nftApprovalsTakenBack;
    uint256 public treasuryProposalsLeftPending;

    constructor(
        Prenda prenda_,
        TestUSDT0 usdt_,
        OpenMarketMock market_,
        address admin_,
        address pauser_,
        address secondTreasury
    ) {
        prenda = prenda_;
        usdt = usdt_;
        market = market_;
        admin = admin_;
        pauser = pauser_;
        treasuries = [prenda_.treasury(), secondTreasury];
        treasuryBook = treasuries[0];
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string.concat("actor ", vm.toString(i))));
        }
    }

    function book(uint256 tokenId) external view returns (Book memory) {
        return _books[tokenId];
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

    function _pick(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (minted == 0) return (0, false);
        return (1 + (seed % minted), true);
    }

    /// @dev Half of the time the last NFT whose approval was given, when there is one; otherwise any NFT.
    function _pickApproved(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        if (_lastApproved != 0 && seed % 2 == 0) return (_lastApproved, true);
        return _pick(seed >> 1);
    }

    /// @dev The rule of the contract, from the books: who may be the one that executes a transfer.
    function mayMoveTokens(address account) public view returns (bool) {
        if (account == address(market)) return !marketDisabledBook;
        return openBook;
    }

    /// @dev From the books: `operator` holds an approval of `holder` that covers this NFT.
    function _approvedBy(address holder, address operator, uint256 tokenId) internal view returns (bool) {
        return approvedForAllBook[holder][operator] || _books[tokenId].approved == operator;
    }

    /// @dev One of the wallets or the market.
    function _operator(uint256 seed) internal view returns (address) {
        uint256 choice = seed % (actors.length + 1);
        return choice == actors.length ? address(market) : actors[choice];
    }

    // ------------------------------------------------------------------------------------------------------- sale

    function sell(uint256 actorSeed, uint32 freePeriod, uint80 feePerPeriod, uint80 maxFee) external {
        freePeriod = uint32(bound(freePeriod, 0, 400 days));
        feePerPeriod = uint80(bound(feePerPeriod, 0, 50 * 10 ** 6));
        maxFee = feePerPeriod == 0 ? 0 : uint80(bound(maxFee, feePerPeriod, 500 * 10 ** 6));
        address to = _actor(actorSeed);
        uint256 tokenId = minted + 1;
        bool paused = pausedBook;

        try
            prenda.mint(
                to,
                tokenId,
                Prenda.StorageTerms({freePeriod: freePeriod, feePerPeriod: feePerPeriod, maxFee: maxFee}),
                keccak256(abi.encode(tokenId))
            )
        {
            if (paused) violations.push("mint worked while paused");
            minted = tokenId;
            liveCount += 1;
            _books[tokenId] = Book({
                burned: false,
                holder: to,
                originalFreeUntil: uint48(block.timestamp + freePeriod),
                freeUntil: uint48(block.timestamp + freePeriod),
                feePerPeriod: feePerPeriod,
                maxFee: maxFee,
                moves: 0,
                approved: address(0)
            });
        } catch {
            if (!paused) violations.push("mint failed while not paused");
            else blockedByPause += 1;
        }
    }

    function sellAUsedNumberAgain(uint256 tokenSeed, uint256 actorSeed) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok) return;
        try
            prenda.mint(
                _actor(actorSeed),
                tokenId,
                Prenda.StorageTerms({freePeriod: 0, feePerPeriod: 0, maxFee: 0}),
                keccak256("again")
            )
        {
            violations.push("a used token id was minted again");
        } catch {}
    }

    // -------------------------------------------------------------------------------------------------- approvals

    function approveMarketForAll(uint256 actorSeed, bool approved) external {
        address holder = _actor(actorSeed);
        _setApprovalForAll(holder, address(market), approved);
    }

    /// @dev A holder approves a wallet or the market, for all its NFTs and for one of them.
    function approveSomeoneElse(uint256 actorSeed, uint256 operatorSeed, uint256 tokenSeed) external {
        address operator = _operator(operatorSeed);
        _setApprovalForAll(_actor(actorSeed), operator, true);

        (uint256 tokenId, bool ok) = _pickApproved(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        _approve(tokenId, operator);
    }

    /// @dev A holder takes approvals back: the one for all its NFTs from a wallet or the market, and the one of
    /// an NFT whoever has it.
    function takeApprovalsBack(uint256 actorSeed, uint256 operatorSeed, uint256 tokenSeed) external {
        _setApprovalForAll(_actor(actorSeed), _operator(operatorSeed), false);

        (uint256 tokenId, bool ok) = _pickApproved(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        _approve(tokenId, address(0));
    }

    function _setApprovalForAll(address holder, address operator, bool approved) internal {
        bool expected = !approved || mayMoveTokens(operator);
        vm.prank(holder);
        try prenda.setApprovalForAll(operator, approved) {
            if (!expected) violations.push("an account that may not move NFTs got an approval for all");
            if (!approved && approvedForAllBook[holder][operator]) {
                revokedForAllBook[holder][operator] += 1;
                approvalsForAllTakenBack += 1;
            }
            approvedForAllBook[holder][operator] = approved;
        } catch {
            if (!approved) violations.push("taking back an approval for all failed");
            else if (expected) violations.push("an approval for all that should work failed");
        }
    }

    /// @dev The holder of the NFT approves `operator` for it, or clears the approval with the zero address.
    function _approve(uint256 tokenId, address operator) internal {
        Book memory b = _books[tokenId];
        bool expected = operator == address(0) || mayMoveTokens(operator);
        vm.prank(b.holder);
        try prenda.approve(operator, tokenId) {
            if (!expected) violations.push("an account that may not move NFTs got the approval of an NFT");
            if (b.approved != address(0) && b.approved != operator) {
                revokedForNftBook[tokenId][b.approved] += 1;
                nftApprovalsTakenBack += 1;
            }
            _books[tokenId].approved = operator;
            if (operator != address(0)) _lastApproved = tokenId;
        } catch {
            if (operator == address(0)) violations.push("clearing the approval of an NFT failed");
            else if (expected) violations.push("the approval of an NFT that should work failed");
        }
    }

    /// @dev Only holders approve. The market, whatever approvals it holds, must never manage to approve anybody.
    function marketPassesItsPermissionOn(uint256 tokenSeed, uint256 toSeed) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        address target = toSeed % 5 == 4 ? address(market) : _actor(toSeed);
        try market.grant(target, tokenId) {
            violations.push("a market gave an approval on behalf of a holder");
        } catch {
            refusedGrants += 1;
        }
    }

    // -------------------------------------------------------------------------------------------------- transfers

    function resellThroughTheMarket(uint256 tokenSeed, uint256 buyerSeed) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        address seller = _books[tokenId].holder;
        address buyer = _actor(buyerSeed);
        bool paused = pausedBook;
        bool expected = _approvedBy(seller, address(market), tokenId) && !paused && !marketDisabledBook;

        try market.move(seller, buyer, tokenId) {
            if (!expected) violations.push("the market moved an NFT it should not have moved");
            _books[tokenId].holder = buyer;
            _books[tokenId].moves += 1;
            _books[tokenId].approved = address(0);
            marketMoves += 1;
        } catch {
            if (expected) violations.push("the market could not move an approved NFT");
            if (paused) blockedByPause += 1;
        }
    }

    function transferDirectly(uint256 tokenSeed, uint256 executorSeed, uint256 toSeed) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        address holder = _books[tokenId].holder;
        address to = _actor(toSeed);
        // Half of the time the executor is the holder itself; otherwise one of the wallets, the administration,
        // the treasury or this minter.
        uint256 choice = (executorSeed >> 1) % (actors.length + 3);
        address executor = executorSeed % 2 == 0 ? holder : choice < actors.length
            ? actors[choice]
            : choice == actors.length ? admin : choice == actors.length + 1 ? treasuryBook : address(this);
        bool open = openBook;
        bool paused = pausedBook;
        bool entitled = executor == holder || _approvedBy(holder, executor, tokenId);

        vm.prank(executor);
        try prenda.transferFrom(holder, to, tokenId) {
            if (!open) violations.push("an NFT moved outside a market while transfers were closed");
            if (paused) violations.push("an NFT moved while paused");
            if (!entitled) violations.push("an NFT was moved by someone without the holder's permission");
            _books[tokenId].holder = to;
            _books[tokenId].moves += 1;
            _books[tokenId].approved = address(0);
            directMoves += 1;
        } catch {
            if (open && !paused && entitled) violations.push("a legitimate direct transfer failed after opening");
        }
    }

    /// @dev An NFT held by the NFT contract would be lost. Neither the market nor its holder can send it there.
    function sendToTheNftContract(uint256 tokenSeed) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        address holder = _books[tokenId].holder;

        try market.move(holder, address(prenda), tokenId) {
            violations.push("the market sent an NFT to the NFT contract");
        } catch {}
        vm.prank(holder);
        try prenda.transferFrom(holder, address(prenda), tokenId) {
            violations.push("a holder sent an NFT to the NFT contract");
        } catch {}
    }

    // ----------------------------------------------------------------------------------------------------- claims

    function claim(uint256 tokenSeed, uint256 extraAccepted) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        Book memory b = _books[tokenId];
        // The fee by the books. The claimer brings exactly that much, so a claim that charged anything else fails
        // or leaves a balance that does not match.
        uint256 fee = _fee(b);
        if (prenda.storageFeeOf(tokenId) != fee) violations.push("the storage fee is not what the books give");
        if (fee > _originalFee(b)) violations.push("the storage fee is above what the original terms give");
        if (fee > b.maxFee) violations.push("the storage fee is above its ceiling");

        address currentTreasury = treasuryBook;
        uint256 treasuryBefore = usdt.balanceOf(currentTreasury);
        uint256 accepted = fee + bound(extraAccepted, 0, 10 ** 12);

        vm.startPrank(b.holder);
        usdt.mint(fee);
        usdt.approve(address(prenda), accepted);
        try prenda.claim(tokenId, accepted, bytes32(tokenId)) {
            if (usdt.balanceOf(currentTreasury) - treasuryBefore != fee) {
                violations.push("the treasury did not get exactly the fee");
            }
            if (usdt.balanceOf(b.holder) != 0) violations.push("the claimer paid something other than the fee");
            _books[tokenId].burned = true;
            _books[tokenId].approved = address(0);
            liveCount -= 1;
            feesPaid += fee;
            if (fee == 0) freeClaims += 1;
            else paidClaims += 1;
        } catch {
            violations.push("the holder could not claim");
        }
        usdt.approve(address(prenda), 0);
        vm.stopPrank();
    }

    function claimSomebodyElsesGarment(uint256 tokenSeed, uint256 claimerSeed) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok) return;
        uint256 choice = claimerSeed % (actors.length + 3);
        address claimer = choice < actors.length ? actors[choice] : choice == actors.length
            ? admin
            : choice == actors.length + 1 ? address(market) : address(this);
        if (!_books[tokenId].burned && claimer == _books[tokenId].holder) return;

        vm.prank(claimer);
        try prenda.claim(tokenId, type(uint256).max, bytes32(tokenId)) {
            violations.push("someone who is not the holder claimed, or a burned NFT was claimed again");
        } catch {}
    }

    // --------------------------------------------------------------------------------------------- administration

    /// @dev More free storage for one garment. The new date is later than the one in force; it is accepted only
    /// if it is no further than the limit from now.
    function waiveStorage(uint256 tokenSeed, uint48 extra) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        uint48 current = _freeUntil(_books[tokenId]);
        uint48 next = uint48(bound(extra, uint256(current) + 1, uint256(current) + 400 days));
        bool expected = next <= block.timestamp + MAX_WAIVER;
        uint256 feeBefore = _fee(_books[tokenId]);

        vm.prank(admin);
        try prenda.extendFreeStorage(tokenId, next) {
            if (!expected) violations.push("a waiver went beyond the limit");
            _books[tokenId].freeUntil = next;
            uint256 feeAfter = prenda.storageFeeOf(tokenId);
            if (feeAfter != _fee(_books[tokenId])) violations.push("after a waiver the fee is not what the books give");
            if (feeAfter > feeBefore) violations.push("a waiver raised the fee");
            waivers += 1;
        } catch {
            if (expected) violations.push("a valid waiver failed");
            waiversBeyondTheLimit += 1;
        }
    }

    function tryToShortenFreeStorage(uint256 tokenSeed, uint48 earlier) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        earlier = uint48(bound(earlier, 0, _freeUntil(_books[tokenId])));
        vm.prank(admin);
        try prenda.extendFreeStorage(tokenId, earlier) {
            violations.push("free storage was shortened or left equal");
        } catch {}
    }

    /// @dev Free storage for every garment at once. Kept short, so that fees start to add up again afterwards.
    function waiveStorageForAll(uint48 extra) external {
        uint48 current = forAllBook;
        uint256 base = current > block.timestamp ? current : block.timestamp;
        uint48 next = uint48(bound(extra, uint256(current) + 1, base + 20 days));
        bool expected = next <= block.timestamp + MAX_WAIVER;
        (uint256 tokenId, bool ok) = _pick(extra);
        bool sampled = ok && !_books[tokenId].burned;
        uint256 feeBefore = sampled ? _fee(_books[tokenId]) : 0;

        vm.prank(admin);
        try prenda.extendFreeStorageForAll(next) {
            if (!expected) violations.push("a waiver for all went beyond the limit");
            forAllBook = next;
            if (sampled) {
                uint256 feeAfter = prenda.storageFeeOf(tokenId);
                if (feeAfter != _fee(_books[tokenId])) {
                    violations.push("after a waiver for all a fee is not what the books give");
                }
                if (feeAfter > feeBefore) violations.push("a waiver for all raised a fee");
            }
            waiversForAll += 1;
        } catch {
            if (expected) violations.push("a valid waiver for all failed");
            waiversBeyondTheLimit += 1;
        }
    }

    function tryToShortenFreeStorageForAll(uint48 earlier) external {
        earlier = uint48(bound(earlier, 0, forAllBook));
        vm.prank(admin);
        try prenda.extendFreeStorageForAll(earlier) {
            violations.push("free storage for all was shortened or left equal");
        } catch {}
    }

    /// @dev A date further than the limit from now must be refused, for every garment and for one.
    function tryToWaiveBeyondTheLimit(uint256 tokenSeed, uint48 far) external {
        far = uint48(bound(far, block.timestamp + MAX_WAIVER + 1, type(uint48).max));
        vm.startPrank(admin);
        try prenda.extendFreeStorageForAll(far) {
            violations.push("a waiver for all went beyond the limit");
        } catch {
            waiversBeyondTheLimit += 1;
        }
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (ok && !_books[tokenId].burned) {
            try prenda.extendFreeStorage(tokenId, far) {
                violations.push("a waiver went beyond the limit");
            } catch {
                waiversBeyondTheLimit += 1;
            }
        }
        vm.stopPrank();
    }

    /// @dev Half of the time it is the account that can only pause that pauses; only the administration resumes.
    function setPaused(bool paused, bool byPauser) external {
        if (paused == pausedBook) return;
        if (paused) {
            vm.prank(byPauser ? pauser : admin);
            prenda.pause();
        } else {
            vm.prank(pauser);
            try prenda.unpause() {
                violations.push("the account that can only pause resumed sales");
            } catch {}
            vm.prank(admin);
            prenda.unpause();
        }
        pausedBook = paused;
    }

    /// @dev The administration proposes one of the two treasuries. Nothing changes unless that one accepts, and
    /// nobody else can accept in its place.
    function changeTreasury(uint256 seed, bool accepts) external {
        address next = treasuries[seed % 2];
        address other = treasuries[1 - (seed % 2)];
        vm.prank(admin);
        prenda.proposeTreasury(next);
        pendingTreasuryBook = next;

        vm.prank(other);
        try prenda.acceptTreasury() {
            violations.push("an account that was not proposed became the treasury");
        } catch {}
        if (!accepts) {
            treasuryProposalsLeftPending += 1;
            return;
        }
        vm.prank(next);
        prenda.acceptTreasury();
        treasuryBook = next;
        pendingTreasuryBook = address(0);
    }

    /// @dev Rare on purpose: most sequences should spend their time with transfers closed.
    function openTransfers(uint256 seed) external {
        if (seed % 16 != 0 || openBook) return;
        vm.prank(admin);
        prenda.openTransfers();
        openBook = true;
    }

    function disableTheMarket(uint256 seed) external {
        if (seed % 24 != 0 || marketDisabledBook) return;
        vm.prank(admin);
        prenda.disableMarket(address(market));
        marketDisabledBook = true;
    }

    function letTimePass(uint32 time) external {
        vm.warp(block.timestamp + bound(time, 1, 120 days));
    }

    // --------------------------------------------------------------------------------------------------- the rule

    function originalFee(uint256 tokenId) external view returns (uint256) {
        return _originalFee(_books[tokenId]);
    }

    function feeOf(uint256 tokenId) external view returns (uint256) {
        return _fee(_books[tokenId]);
    }

    function freeUntilOf(uint256 tokenId) external view returns (uint48) {
        return _freeUntil(_books[tokenId]);
    }

    /// @dev The end of free storage in force: the garment's own or the one given to all, whichever is later.
    function _freeUntil(Book memory b) internal view returns (uint48) {
        return b.freeUntil > forAllBook ? b.freeUntil : forAllBook;
    }

    /// @dev The fee by the books, waivers included.
    function _fee(Book memory b) internal view returns (uint256) {
        return _feeFrom(_freeUntil(b), b);
    }

    /// @dev Fee according to the terms fixed at the sale, ignoring any waiver. Nothing may ever charge more.
    function _originalFee(Book memory b) internal view returns (uint256) {
        return _feeFrom(b.originalFreeUntil, b);
    }

    /// @dev The storage rule: nothing until 30 full days after the end of free storage, then one instalment for
    /// every full 30 days, up to the ceiling.
    function _feeFrom(uint256 freeUntil, Book memory b) internal view returns (uint256) {
        if (block.timestamp < freeUntil + 30 days) return 0;
        uint256 instalments = (block.timestamp - freeUntil) / 30 days;
        uint256 fee = instalments * b.feePerPeriod;
        return fee > b.maxFee ? b.maxFee : fee;
    }
}

contract PrendaInvariantTest is Test {
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal secondTreasury = makeAddr("second treasury");
    address internal pauser = makeAddr("pauser");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    OpenMarketMock internal market;
    PrendaHandler internal handler;

    function setUp() public {
        usdt = new TestUSDT0();
        prenda = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, "https://example.test/nft/");
        market = new OpenMarketMock(prenda);
        handler = new PrendaHandler(prenda, usdt, market, admin, pauser, secondTreasury);

        vm.startPrank(admin);
        prenda.setMinter(address(handler), true);
        prenda.authorizeMarket(address(market));
        prenda.setPauser(pauser);
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = PrendaHandler.sell.selector;
        selectors[1] = PrendaHandler.sellAUsedNumberAgain.selector;
        selectors[2] = PrendaHandler.approveMarketForAll.selector;
        selectors[3] = PrendaHandler.approveSomeoneElse.selector;
        selectors[4] = PrendaHandler.marketPassesItsPermissionOn.selector;
        selectors[5] = PrendaHandler.resellThroughTheMarket.selector;
        selectors[6] = PrendaHandler.transferDirectly.selector;
        selectors[7] = PrendaHandler.sendToTheNftContract.selector;
        selectors[8] = PrendaHandler.claim.selector;
        selectors[9] = PrendaHandler.claimSomebodyElsesGarment.selector;
        selectors[10] = PrendaHandler.waiveStorage.selector;
        selectors[11] = PrendaHandler.tryToShortenFreeStorage.selector;
        selectors[12] = PrendaHandler.setPaused.selector;
        selectors[13] = PrendaHandler.changeTreasury.selector;
        selectors[14] = PrendaHandler.openTransfers.selector;
        selectors[15] = PrendaHandler.disableTheMarket.selector;
        selectors[16] = PrendaHandler.letTimePass.selector;
        selectors[17] = PrendaHandler.waiveStorageForAll.selector;
        selectors[18] = PrendaHandler.tryToShortenFreeStorageForAll.selector;
        selectors[19] = PrendaHandler.takeApprovalsBack.selector;
        selectors[20] = PrendaHandler.tryToWaiveBeyondTheLimit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Nothing forbidden happened and nothing allowed failed.
    function invariant_NothingForbiddenHappened() public view {
        if (handler.violationCount() != 0) revert(handler.violations(0));
    }

    /// @dev The contract never keeps payment tokens, and every fee reached a treasury.
    function invariant_NoBalanceIsKeptAndEveryFeeReachedATreasury() public view {
        assertEq(usdt.balanceOf(address(prenda)), 0);
        assertEq(usdt.balanceOf(treasury) + usdt.balanceOf(secondTreasury), handler.feesPaid());
        assertEq(usdt.totalSupply(), handler.feesPaid());
    }

    /// @dev ERC-721 bookkeeping: balances add up to the NFTs alive, and the NFT contract never holds one.
    function invariant_BalancesAddUpToTheNftsAlive() public view {
        uint256 total;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            total += prenda.balanceOf(handler.actors(i));
        }
        assertEq(total, handler.liveCount());
        assertEq(prenda.balanceOf(address(prenda)), 0);
    }

    /// @dev Every token id ever used: its holder, its terms, its fee, its transfer count and its fingerprint.
    function invariant_EveryTokenMatchesTheBooks() public view {
        uint256 minted = handler.minted();
        for (uint256 tokenId = 1; tokenId <= minted; tokenId++) {
            PrendaHandler.Book memory b = handler.book(tokenId);
            assertTrue(prenda.isTokenIdUsed(tokenId));
            assertEq(prenda.contentHashOf(tokenId), keccak256(abi.encode(tokenId)));
            assertEq(prenda.transferCountOf(tokenId), b.moves);

            (uint48 freeUntil, uint80 feePerPeriod, uint80 maxFee) = prenda.storageTermsOf(tokenId);
            assertEq(feePerPeriod, b.feePerPeriod);
            assertEq(maxFee, b.maxFee);
            assertEq(freeUntil, handler.freeUntilOf(tokenId));
            assertGe(freeUntil, b.originalFreeUntil);

            if (b.burned) {
                try prenda.ownerOf(tokenId) returns (address) {
                    revert("a burned NFT has a holder");
                } catch {}
            } else {
                assertEq(prenda.ownerOf(tokenId), b.holder);
                // The approval of an NFT is reported only while the approved account may move NFTs.
                assertEq(prenda.getApproved(tokenId), handler.mayMoveTokens(b.approved) ? b.approved : address(0));
                uint256 fee = prenda.storageFeeOf(tokenId);
                assertEq(fee, handler.feeOf(tokenId));
                assertLe(fee, maxFee);
                assertLe(fee, handler.originalFee(tokenId));
            }
        }
        assertFalse(prenda.isTokenIdUsed(minted + 1));
    }

    /// @dev The pause, the one-way switches, the date of free storage for all, the treasury in force and the one
    /// proposed, every approval for all and every count of approvals taken back.
    function invariant_SwitchesAndApprovalsMatchTheBooks() public view {
        assertEq(prenda.paused(), handler.pausedBook());
        assertEq(prenda.freeStorageForAllUntil(), handler.forAllBook());
        assertEq(prenda.treasury(), handler.treasuryBook());
        assertEq(prenda.pendingTreasury(), handler.pendingTreasuryBook());
        assertEq(prenda.transfersOpen(), handler.openBook());
        assertEq(
            uint8(prenda.marketStatus(address(market))),
            uint8(handler.marketDisabledBook() ? Prenda.MarketStatus.Disabled : Prenda.MarketStatus.Authorized)
        );

        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address holder = handler.actors(i);
            for (uint256 j = 0; j <= count; j++) {
                address operator = j == count ? address(market) : handler.actors(j);
                assertEq(
                    prenda.approvalsForAllRevoked(holder, operator),
                    handler.revokedForAllBook(holder, operator)
                );
                // An approval for all counts only while its operator may move NFTs.
                assertEq(
                    prenda.isApprovedForAll(holder, operator),
                    handler.approvedForAllBook(holder, operator) && handler.mayMoveTokens(operator)
                );
            }
        }

        // How often the approval of each NFT was taken back from each account that ever had one.
        uint256 minted = handler.minted();
        for (uint256 tokenId = 1; tokenId <= minted; tokenId++) {
            for (uint256 j = 0; j <= count; j++) {
                address operator = j == count ? address(market) : handler.actors(j);
                assertEq(
                    prenda.tokenApprovalsRevoked(tokenId, operator),
                    handler.revokedForNftBook(tokenId, operator)
                );
            }
        }
    }

    /**
     * @dev The same handler driven by fixed pseudo-random sequences, so that every run is the same and the tests
     * can check how often each path was really taken. Transfers are opened in the last third of each walk and the
     * market is disabled near its end. There are several short walks instead of a long one: a failing walk prints
     * every call it made, and a long one runs out of memory before it can report.
     */
    function test_FixedRandomWalkA() public {
        _walk("walk a");
    }

    function test_FixedRandomWalkB() public {
        _walk("walk b");
    }

    function test_FixedRandomWalkC() public {
        _walk("walk c");
    }

    function test_FixedRandomWalkD() public {
        _walk("walk d");
    }

    function _walk(string memory name) internal {
        uint256 steps = 800;
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(name, i)));
            uint256 a = uint256(keccak256(abi.encode(r, uint256(1))));
            uint256 b = uint256(keccak256(abi.encode(r, uint256(2))));
            uint256 c = uint256(keccak256(abi.encode(r, uint256(3))));
            uint256 kind = r % 100;

            if (kind < 22) handler.sell(a, uint32(b), uint80(c), uint80(a >> 80));
            else if (kind < 25) handler.sellAUsedNumberAgain(a, b);
            else if (kind < 34) handler.approveMarketForAll(a, b % 4 != 0);
            else if (kind < 38) handler.approveSomeoneElse(a, b, c);
            else if (kind < 41) handler.takeApprovalsBack(a, b, c);
            else if (kind < 58) handler.resellThroughTheMarket(a, b);
            else if (kind < 66) handler.transferDirectly(a, b, c);
            else if (kind < 76) handler.claim(a, b);
            else if (kind < 81) handler.claimSomebodyElsesGarment(a, b);
            else if (kind < 86) handler.waiveStorage(a, uint48(b));
            else if (kind < 89) handler.tryToShortenFreeStorage(a, uint48(b));
            else if (kind < 92) handler.setPaused(a % 3 == 0, b % 2 == 0);
            else if (kind < 94) handler.changeTreasury(a, b % 3 != 0);
            else handler.letTimePass(uint32(a));

            // Attempts that must always fail and so never change the walk.
            if (i % 7 == 3) handler.marketPassesItsPermissionOn(b, c);
            if (i % 11 == 5) handler.sendToTheNftContract(c);
            if (i % 150 == 75) handler.waiveStorageForAll(uint48(a));
            if (i % 97 == 50) handler.tryToShortenFreeStorageForAll(uint48(b));
            if (i % 53 == 20) handler.tryToWaiveBeyondTheLimit(a, uint48(c));

            if (i == (steps * 2) / 3) handler.openTransfers(0);
            if (i == steps - 100) handler.disableTheMarket(0);
            if (i % 100 == 0) _checkEverything();
        }
        _checkEverything();

        // Each walk must really have gone through the interesting paths.
        assertGt(handler.minted(), 40);
        assertGt(handler.marketMoves(), 7);
        assertGt(handler.directMoves(), 0);
        assertGt(handler.paidClaims(), 8);
        assertGt(handler.freeClaims(), 7);
        assertGt(handler.waivers(), 9);
        assertGt(handler.waiversForAll(), 2);
        assertGt(handler.waiversBeyondTheLimit(), 10);
        assertGt(handler.blockedByPause(), 20);
        assertGt(handler.refusedGrants(), 25);
        assertGt(handler.approvalsForAllTakenBack(), 8);
        assertGt(handler.nftApprovalsTakenBack(), 1);
        assertGt(handler.treasuryProposalsLeftPending(), 1);
        assertTrue(prenda.transfersOpen());
        assertEq(uint8(prenda.marketStatus(address(market))), uint8(Prenda.MarketStatus.Disabled));
    }

    function _checkEverything() internal view {
        invariant_NothingForbiddenHappened();
        invariant_NoBalanceIsKeptAndEveryFeeReachedATreasury();
        invariant_BalancesAddUpToTheNftsAlive();
        invariant_EveryTokenMatchesTheBooks();
        invariant_SwitchesAndApprovalsMatchTheBooks();
    }
}
