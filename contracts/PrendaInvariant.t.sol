// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Prenda} from "./Prenda.sol";
import {OpenMarketMock} from "./mocks/OpenMarketMock.sol";
import {TestUSDT0} from "./mocks/TestUSDT0.sol";

/**
 * @notice Random sequences of everything that can happen to the NFT contract: sales, resales through the market,
 * direct transfer attempts, claims, attempts by the wrong party, storage waivers, pauses, treasury changes, opening
 * transfers and disabling the market. The handler keeps its own books and writes down anything that must never
 * happen; after every step the invariants compare the contract with those books.
 *
 * The handler plays the sale module: it is the minter, and it names the NFT contract through `prenda()`.
 */
contract PrendaHandler is Test {
    struct Book {
        bool burned;
        address holder;
        uint48 originalFreeUntil;
        uint80 feePerPeriod;
        uint80 maxFee;
        uint32 moves;
    }

    Prenda public immutable prenda;
    TestUSDT0 public immutable usdt;
    OpenMarketMock public immutable market;
    address public immutable admin;

    address[] public actors;
    address[2] public treasuries;

    uint256 public minted;
    uint256 public liveCount;
    uint256 public feesPaid;
    mapping(uint256 tokenId => Book) internal _books;

    /// @dev Things that must never happen. The invariant test requires this list to stay empty.
    string[] public violations;

    // Counters, so that the fixed walk can check that the interesting paths were really taken.
    uint256 public marketMoves;
    uint256 public directMoves;
    uint256 public paidClaims;
    uint256 public freeClaims;
    uint256 public blockedByPause;
    uint256 public waivers;
    uint256 public refusedGrants;

    constructor(Prenda prenda_, TestUSDT0 usdt_, OpenMarketMock market_, address admin_, address secondTreasury) {
        prenda = prenda_;
        usdt = usdt_;
        market = market_;
        admin = admin_;
        treasuries = [prenda_.treasury(), secondTreasury];
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

    function _marketIsAuthorized() internal view returns (bool) {
        return prenda.marketStatus(address(market)) == Prenda.MarketStatus.Authorized;
    }

    // ------------------------------------------------------------------------------------------------------- sale

    function sell(uint256 actorSeed, uint32 freePeriod, uint80 feePerPeriod, uint80 maxFee) external {
        freePeriod = uint32(bound(freePeriod, 0, 400 days));
        feePerPeriod = uint80(bound(feePerPeriod, 0, 50 * 10 ** 6));
        maxFee = feePerPeriod == 0 ? 0 : uint80(bound(maxFee, feePerPeriod, 500 * 10 ** 6));
        address to = _actor(actorSeed);
        uint256 tokenId = minted + 1;
        bool paused = prenda.paused();

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
                feePerPeriod: feePerPeriod,
                maxFee: maxFee,
                moves: 0
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
        vm.prank(_actor(actorSeed));
        try prenda.setApprovalForAll(address(market), approved) {
            if (approved && !_marketIsAuthorized()) violations.push("a disabled market was approved");
        } catch {
            if (!approved) violations.push("a revocation failed");
            else if (_marketIsAuthorized()) violations.push("the approval of an authorized market failed");
        }
    }

    function approveSomeoneElse(uint256 actorSeed, uint256 operatorSeed, uint256 tokenSeed) external {
        address holder = _actor(actorSeed);
        address operator = _actor(operatorSeed);
        bool open = prenda.transfersOpen();
        vm.prank(holder);
        try prenda.setApprovalForAll(operator, true) {
            if (!open) violations.push("a non-market got an approval for all while transfers were closed");
        } catch {}

        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        vm.prank(_books[tokenId].holder);
        try prenda.approve(operator, tokenId) {
            if (!open) violations.push("a non-market got a token approval while transfers were closed");
        } catch {}
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
        bool approved = prenda.isApprovedForAll(seller, address(market)) ||
            prenda.getApproved(tokenId) == address(market);
        bool paused = prenda.paused();
        bool expected = approved && !paused && _marketIsAuthorized();

        try market.move(seller, buyer, tokenId) {
            if (!expected) violations.push("the market moved an NFT it should not have moved");
            _books[tokenId].holder = buyer;
            _books[tokenId].moves += 1;
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
        // The executor is a holder, the administration, the treasury or this minter.
        uint256 choice = executorSeed % (actors.length + 3);
        address executor = choice < actors.length ? actors[choice] : choice == actors.length
            ? admin
            : choice == actors.length + 1 ? prenda.treasury() : address(this);
        bool open = prenda.transfersOpen();
        bool paused = prenda.paused();
        bool entitled = executor == holder ||
            prenda.isApprovedForAll(holder, executor) ||
            prenda.getApproved(tokenId) == executor;

        vm.prank(executor);
        try prenda.transferFrom(holder, to, tokenId) {
            if (!open) violations.push("an NFT moved outside a market while transfers were closed");
            if (paused) violations.push("an NFT moved while paused");
            if (!entitled) violations.push("an NFT was moved by someone without the holder's permission");
            _books[tokenId].holder = to;
            _books[tokenId].moves += 1;
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
        uint256 fee = prenda.storageFeeOf(tokenId);
        if (fee > _originalFee(b)) violations.push("the storage fee is above what the original terms give");
        if (fee > b.maxFee) violations.push("the storage fee is above its ceiling");

        address currentTreasury = prenda.treasury();
        uint256 treasuryBefore = usdt.balanceOf(currentTreasury);
        uint256 accepted = fee + bound(extraAccepted, 0, 10 ** 12);

        vm.startPrank(b.holder);
        usdt.mint(fee);
        usdt.approve(address(prenda), accepted);
        try prenda.claim(tokenId, accepted) {
            if (usdt.balanceOf(currentTreasury) - treasuryBefore != fee) {
                violations.push("the treasury did not get exactly the fee");
            }
            if (usdt.balanceOf(b.holder) != 0) violations.push("the claimer paid something other than the fee");
            _books[tokenId].burned = true;
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
        try prenda.claim(tokenId, type(uint256).max) {
            violations.push("someone who is not the holder claimed, or a burned NFT was claimed again");
        } catch {}
    }

    // --------------------------------------------------------------------------------------------- administration

    function waiveStorage(uint256 tokenSeed, uint48 extra) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        (uint48 current, , ) = prenda.storageTermsOf(tokenId);
        uint48 next = uint48(bound(extra, uint256(current) + 1, uint256(current) + 400 days));
        uint256 feeBefore = prenda.storageFeeOf(tokenId);
        vm.prank(admin);
        prenda.extendFreeStorage(tokenId, next);
        if (prenda.storageFeeOf(tokenId) > feeBefore) violations.push("a waiver raised the fee");
        waivers += 1;
    }

    function tryToShortenFreeStorage(uint256 tokenSeed, uint48 earlier) external {
        (uint256 tokenId, bool ok) = _pick(tokenSeed);
        if (!ok || _books[tokenId].burned) return;
        (uint48 current, , ) = prenda.storageTermsOf(tokenId);
        earlier = uint48(bound(earlier, 0, current));
        vm.prank(admin);
        try prenda.extendFreeStorage(tokenId, earlier) {
            violations.push("free storage was shortened or left equal");
        } catch {}
    }

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

    /// @dev Rare on purpose: most sequences should spend their time with transfers closed.
    function openTransfers(uint256 seed) external {
        if (seed % 16 != 0 || prenda.transfersOpen()) return;
        vm.prank(admin);
        prenda.openTransfers();
    }

    function disableTheMarket(uint256 seed) external {
        if (seed % 24 != 0 || !_marketIsAuthorized()) return;
        vm.prank(admin);
        prenda.disableMarket(address(market));
    }

    function letTimePass(uint32 time) external {
        vm.warp(block.timestamp + bound(time, 1, 120 days));
    }

    // --------------------------------------------------------------------------------------------------- the rule

    function originalFee(uint256 tokenId) external view returns (uint256) {
        return _originalFee(_books[tokenId]);
    }

    /// @dev Fee according to the terms fixed at the sale, ignoring any waiver. Nothing may ever charge more.
    function _originalFee(Book memory b) internal view returns (uint256) {
        if (block.timestamp < uint256(b.originalFreeUntil) + 30 days) return 0;
        uint256 instalments = (block.timestamp - b.originalFreeUntil) / 30 days;
        uint256 fee = instalments * b.feePerPeriod;
        return fee > b.maxFee ? b.maxFee : fee;
    }
}

contract PrendaInvariantTest is Test {
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal secondTreasury = makeAddr("second treasury");

    TestUSDT0 internal usdt;
    Prenda internal prenda;
    OpenMarketMock internal market;
    PrendaHandler internal handler;

    function setUp() public {
        usdt = new TestUSDT0();
        prenda = new Prenda("Allka Archivo", "ALLKA", usdt, treasury, admin, "https://example.test/nft/");
        market = new OpenMarketMock(prenda);
        handler = new PrendaHandler(prenda, usdt, market, admin, secondTreasury);

        vm.startPrank(admin);
        prenda.setMinter(address(handler), true);
        prenda.authorizeMarket(address(market));
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](17);
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
            assertGe(freeUntil, b.originalFreeUntil);

            if (b.burned) {
                try prenda.ownerOf(tokenId) returns (address) {
                    revert("a burned NFT has a holder");
                } catch {}
            } else {
                assertEq(prenda.ownerOf(tokenId), b.holder);
                uint256 fee = prenda.storageFeeOf(tokenId);
                assertLe(fee, maxFee);
                assertLe(fee, handler.originalFee(tokenId));
            }
        }
        assertFalse(prenda.isTokenIdUsed(minted + 1));
    }

    /**
     * @dev The same handler driven by a fixed pseudo-random sequence, so that the run is always the same and the
     * test can check how often each path was really taken. Transfers are opened in the last third and the market
     * is disabled near the end.
     */
    function test_FixedRandomWalkKeepsEveryInvariant() public {
        uint256 steps = 3000;
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode("walk", i)));
            uint256 a = uint256(keccak256(abi.encode(r, uint256(1))));
            uint256 b = uint256(keccak256(abi.encode(r, uint256(2))));
            uint256 c = uint256(keccak256(abi.encode(r, uint256(3))));
            uint256 kind = r % 100;

            if (kind < 22) handler.sell(a, uint32(b), uint80(c), uint80(a >> 80));
            else if (kind < 25) handler.sellAUsedNumberAgain(a, b);
            else if (kind < 35) handler.approveMarketForAll(a, b % 4 != 0);
            else if (kind < 40) handler.approveSomeoneElse(a, b, c);
            else if (kind < 58) handler.resellThroughTheMarket(a, b);
            else if (kind < 66) handler.transferDirectly(a, b, c);
            else if (kind < 76) handler.claim(a, b);
            else if (kind < 81) handler.claimSomebodyElsesGarment(a, b);
            else if (kind < 86) handler.waiveStorage(a, uint48(b));
            else if (kind < 89) handler.tryToShortenFreeStorage(a, uint48(b));
            else if (kind < 92) handler.setPaused(a % 3 == 0);
            else if (kind < 94) handler.changeTreasury(a);
            else handler.letTimePass(uint32(a));

            // Attempts that must always fail and so never change the walk.
            if (i % 7 == 3) handler.marketPassesItsPermissionOn(b, c);
            if (i % 11 == 5) handler.sendToTheNftContract(c);

            if (i == (steps * 2) / 3) handler.openTransfers(0);
            if (i == steps - 200) handler.disableTheMarket(0);
            if (i % 100 == 0) _checkEverything();
        }
        _checkEverything();

        // The walk must really have gone through the interesting paths.
        assertGt(handler.minted(), 300);
        assertGt(handler.marketMoves(), 50);
        assertGt(handler.directMoves(), 5);
        assertGt(handler.paidClaims(), 20);
        assertGt(handler.freeClaims(), 20);
        assertGt(handler.waivers(), 20);
        assertGt(handler.blockedByPause(), 20);
        assertGt(handler.refusedGrants(), 100);
        assertTrue(prenda.transfersOpen());
        assertEq(uint8(prenda.marketStatus(address(market))), uint8(Prenda.MarketStatus.Disabled));
    }

    function _checkEverything() internal view {
        invariant_NothingForbiddenHappened();
        invariant_NoBalanceIsKeptAndEveryFeeReachedATreasury();
        invariant_BalancesAddUpToTheNftsAlive();
        invariant_EveryTokenMatchesTheBooks();
    }
}
