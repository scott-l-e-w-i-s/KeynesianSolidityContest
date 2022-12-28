// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { WETH } from "./helpers/WETH.sol";
import { Turnstile } from "./helpers/Turnstile.sol";
import { IWCANTO } from "../src/interfaces/IWCANTO.sol";
import { ITurnstile } from "../src/interfaces/ITurnstile.sol";
import { LoanAuctionHouse } from "../src/LoanAuctionHouse.sol";
import { Note } from "../src/Note.sol";
import { LoanManager } from "../src/LoanManager.sol";

contract HappyFlowTest is Test {
    uint256 public constant PRINCIPAL = 100_000 ether;
    uint16 public constant MAX_RATE = 100; // 10%
    IWCANTO wCanto = IWCANTO(address(new WETH("Wrapped CANTO", "WCANTO")));
    Turnstile turnstile = new Turnstile();
    Note lenderNoteNFT = new Note("Lender Note", "LENDERNOTE");
    Note borrowerNoteNFT = new Note("Borrower Note", "BORROWERNOTE");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    LoanManager loanManager;
    LoanAuctionHouse ah;
    uint256 csrTokenId;

    function setUp() public {
        ah = new LoanAuctionHouse(turnstile, wCanto);
        loanManager = ah.loanManager();

        csrTokenId = turnstile.register(borrower);
    }

    function testHappyFlow() public {
        vm.deal(lender, PRINCIPAL);
        vm.prank(lender);
        wCanto.deposit{value: PRINCIPAL}();
        assertEq(wCanto.balanceOf(lender), PRINCIPAL);

        // Create auction

        vm.startPrank(borrower);
        turnstile.approve(address(ah), csrTokenId);
        ah.startAuction(PRINCIPAL, MAX_RATE, csrTokenId);

        // Bid auction

        changePrank(lender);
        wCanto.approve(address(ah), PRINCIPAL);
        ah.bid(csrTokenId, 10);

        // Finalize auction & create loan

        vm.warp(block.timestamp + ah.AUCTION_DURATION());
        ah.finalizeAuction(csrTokenId);
        (uint256 totalDebtOutstanding,,,,,) = loanManager.loans(csrTokenId);
        assertEq(totalDebtOutstanding, PRINCIPAL);
        vm.stopPrank();

        assertEq(turnstile.ownerOf(csrTokenId), address(loanManager));

        // time warp

        vm.warp(block.timestamp + 730 days);

        // Repay with claimable

        turnstile.distributeFees{value: PRINCIPAL / 2}(csrTokenId);
        loanManager.repayWithClaimable(csrTokenId);
        (totalDebtOutstanding,,,,,) = loanManager.loans(csrTokenId);
        // 100,000 * e^(0.01 * 730/365.25) - 50000 = 52018.737432713690509936...
        assertApproxEqAbs(totalDebtOutstanding, 52018.737432713690509936 * 1e18, 1e6, "wrong debt");

        vm.prank(lender);
        loanManager.withdrawPayable(csrTokenId, PRINCIPAL / 2);
        assertEq(wCanto.balanceOf(lender), PRINCIPAL / 2);

        // Repay with external

        vm.startPrank(borrower);
        wCanto.approve(address(loanManager), totalDebtOutstanding);
        loanManager.repayWithExternal(csrTokenId, totalDebtOutstanding);

        changePrank(lender);
        loanManager.withdrawPayable(csrTokenId, totalDebtOutstanding);
        // 100,000 * e^(0.01 * 730/365.25) = 102018.73743271369050993601134186187150779168870233483849234250119...
        assertApproxEqAbs(wCanto.balanceOf(lender), 102018.7374327136905099 * 1e18, 1e6, "wrong total repaid");

        changePrank(borrower);
        loanManager.withdrawNFT(csrTokenId);
        assertEq(turnstile.ownerOf(csrTokenId), borrower);
    }
}
