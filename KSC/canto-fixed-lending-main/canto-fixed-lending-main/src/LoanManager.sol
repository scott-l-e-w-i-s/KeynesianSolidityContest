// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ITurnstile } from "./interfaces/ITurnstile.sol";
import { IWCANTO } from "./interfaces/IWCANTO.sol";
import { Interest } from "./Interest.sol";
import { Note } from "./Note.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LoanManager
 * @notice Represents a fixed rate continuous loan.
 * Allows borrower to pay their debt back via CSR claims or via direct WCANTO payment, until the debt is paid in full.
 * Once paid in full borrower may withdraw their CSR NFT back.
 * Lender can withdraw their payable WCANTO balance at any time when the payable balance is not zero.
 */
contract LoanManager {
    using SafeERC20 for IWCANTO;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   ERRORS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    error OnlyOwner();
    error OnlyLender();
    error OnlyBorrower();
    error LoanNotRepaid();

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   EVENTS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    event LoanCreated(
        uint256 indexed csrTokenId, address lender, address borrower, uint16 rate, uint256 principalAmount
    );
    event RepaidWithCSR(uint256 indexed csrTokenId, uint256 amount, uint256 debtPostPayment, uint256 payableBalance);
    event RepaidWithExternal(
        uint256 indexed csrTokenId, uint256 amount, uint256 debtPostPayment, uint256 payableBalance
    );
    event PayableWithdrawn(uint256 indexed csrTokenId, uint256 amount);
    event CSRWithdrawn(uint256 indexed csrTokenId);

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   IMMUTABLES
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /// @notice only owner is allowed to create new loans
    address immutable owner;

    /// @notice The Wrapped Canto token
    IWCANTO immutable wCanto;

    /// @notice The Turnstile contract
    ITurnstile immutable turnstile;

    /// @notice The lender notes NFT
    Note immutable lenderNote;

    /// @notice The borrower notes NFT
    Note immutable borrowerNote;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   STATE VARIABLES
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    struct Loan {
        /// @notice This loan's outstanding debt, as of the latest update upon loan creation or repayment
        uint256 totalDebtOutstanding;
        /// @notice The last time `totalDebtOutstanding` was updated
        uint256 lastAccrualTime;
        /// @notice The current WCANTO balance available for lender to withdraw
        uint256 payableBalance;
        /// @notice This loan's interest rate (APR), in 10 basis points units, e.g. 10 is 1%
        uint16 rate;
        /// @notice This loan's lender note token ID
        uint256 lenderNoteTokenId;
        /// @notice This loan's borrower note token ID
        uint256 borrowerNoteTokenId;
    }

    /// @dev CSR tokenId => loan
    mapping(uint256 => Loan) public loans;

    constructor(IWCANTO wCanto_, ITurnstile turnstile_) {
        owner = msg.sender;
        wCanto = wCanto_;
        turnstile = turnstile_;
        lenderNote = new Note("Lender Note", "LENDERNOTE");
        borrowerNote = new Note("Borrower Note", "BORROWERNOTE");
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   EXTERNAL TXs
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice Creates a new loan holding a CSR token as collateral that can repay that loan.
     * @dev This can only be called by the owner, which is assumed to be a LoanAuctionHouse
     *   It assumes the WCANTO tokens are sent to the borrower and that the csrToken is sent to this contract,
     *   in this tx, outside of this function.
     *   This was done in order to avoid extra token approval calls.
     * @param csrTokenId token ID of the CSR token to be used as collateral
     * @param lender address of the lender account that is able to withdraw the prinicipal & accrued debt when it's repaid
     * @param borrower address of the borrower account. this account will have permission to withdraw the CSR NFT once loan is fully repaid
     * @param rate annual interest rate in 10 bps units, e.g 15 = 1.5%
     * @param principalAmount the loan principal amount of WCANTO tokens
     */
    function createLoan(uint256 csrTokenId, address lender, address borrower, uint16 rate, uint256 principalAmount)
        external
    {
        if (msg.sender != owner) revert OnlyOwner();

        Loan storage loan = loans[csrTokenId];
        loan.lastAccrualTime = block.timestamp;
        loan.totalDebtOutstanding = principalAmount;
        loan.rate = rate;
        loan.lenderNoteTokenId = lenderNote.mint(lender);
        loan.borrowerNoteTokenId = borrowerNote.mint(borrower);

        emit LoanCreated(csrTokenId, lender, borrower, rate, principalAmount);
    }

    /**
     * @notice Repay debt with CSR balance.
     * Actually pays the lower balance between (1) CSR balance and (2) outstanding debt.
     * @param csrTokenId token ID of the CSR token used as collateral for the loan to repay
     * @return repayAmount the amount of tokens repaid
     */
    function repayWithClaimable(uint256 csrTokenId) external returns (uint256 repayAmount) {
        Loan storage loan = loans[csrTokenId];
        uint256 currentDebt = calculateAccruedDebt(loan);
        repayAmount = Math.min(turnstile.balances(csrTokenId), currentDebt);

        turnstile.withdraw(csrTokenId, payable(address(this)), repayAmount);
        wCanto.deposit{value: repayAmount}();

        loan.lastAccrualTime = block.timestamp;
        loan.totalDebtOutstanding = currentDebt - repayAmount;
        loan.payableBalance += repayAmount;

        emit RepaidWithCSR(csrTokenId, repayAmount, loan.totalDebtOutstanding, loan.payableBalance);
    }

    /**
     * @notice Repay debt by WCANTO transfer.
     * msg.sender must approve this loan contract to perform WCANTO transfers on their behalf of at least `amount`.
     * Actually pays the lower amount between (1) the `amount` input and (2) the outstanding debt.
     * @param csrTokenId token ID of the CSR token used as collateral for the loan to repay
     * @param amount the amount msg.sender would like to pay towards the outstanding debt.
     * @return repayAmount the amount of tokens repaid
     */
    function repayWithExternal(uint256 csrTokenId, uint256 amount) external returns (uint256 repayAmount) {
        Loan storage loan = loans[csrTokenId];
        uint256 currentDebt = calculateAccruedDebt(loan);
        repayAmount = Math.min(amount, currentDebt);

        wCanto.safeTransferFrom(msg.sender, address(this), repayAmount);

        loan.lastAccrualTime = block.timestamp;
        loan.totalDebtOutstanding = currentDebt - repayAmount;
        loan.payableBalance += repayAmount;

        emit RepaidWithExternal(csrTokenId, repayAmount, loan.totalDebtOutstanding, loan.payableBalance);
    }

    /**
     * @notice Withdraw available payable WCANTO balance
     * Reverts if not called by the owner of this loan's lender note.
     * @param csrTokenId token ID of the CSR token used as collateral for the loan to withdraw from
     * @return uint256 amount of withdrawn WCANTO tokens
     */
    function withdrawPayable(uint256 csrTokenId) external returns (uint256) {
        return withdrawPayable(csrTokenId, loans[csrTokenId].payableBalance);
    }

    /**
     * @notice Withdraw payable WCANTO balance.
     * Reverts if not called by the owner of this loan's lender note.
     * Actually transfers the lower amount between (1) the `amount` input and (2) `payableBalance`.
     * @param csrTokenId token ID of the CSR token used as collateral for the loan to withdraw from
     * @param amount the amount to withdraw
     * @return uint256 amount of withdrawn WCANTO tokens
     */
    function withdrawPayable(uint256 csrTokenId, uint256 amount) public returns (uint256) {
        Loan storage loan = loans[csrTokenId];

        address lenderNoteOwner = lenderNote.ownerOf(loan.lenderNoteTokenId);
        if (msg.sender != lenderNoteOwner) revert OnlyLender();

        uint256 actualAmount = Math.min(amount, loan.payableBalance);
        loan.payableBalance -= actualAmount;

        wCanto.safeTransfer(msg.sender, actualAmount);

        emit PayableWithdrawn(csrTokenId, actualAmount);

        return actualAmount;
    }

    /**
     * @notice Withdraw the CSR NFT placed as collateral.
     * Reverts if not called by the owner of this loan's borrower note.
     * Reverts if the loan has not been repaid in full.
     * @param csrTokenId the Id of the CSR token to withdraw
     */
    function withdrawNFT(uint256 csrTokenId) external {
        Loan storage loan = loans[csrTokenId];

        address borrowerNoteOwner = borrowerNote.ownerOf(loan.borrowerNoteTokenId);

        if (msg.sender != borrowerNoteOwner) revert OnlyBorrower();
        if (!isCSRNFTWithdrawable(csrTokenId)) revert LoanNotRepaid();

        delete loans[csrTokenId];

        turnstile.transferFrom(address(this), borrowerNoteOwner, csrTokenId);

        emit CSRWithdrawn(csrTokenId);
    }

    /**
     * @dev Receive is necessary because `Turnstile` claims send native CANTO as payment, which is then wrapped
     * into WCANTO by `LoanManager`.
     */
    receive() external payable { }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   VIEW FUNCTIONS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @return true if the loan has been repaid in full, and false otherwise.
     */
    function isCSRNFTWithdrawable(uint256 csrTokenId) public view returns (bool) {
        return loans[csrTokenId].totalDebtOutstanding == 0;
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   INTERNAL FUNCTIONS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice calculates the updated debt amount since the last accrual time
     * @dev deviated from the original `accrueInterest` specification to save gas; the original spec would have
     * resulted in two SSTOREs to `totalDebtOutstanding`, once on `accrueInterest` and again after processing repayment,
     * while this approach uses only one SSTORE of `totalDebtOutstanding` post-repayment.
     */
    function calculateAccruedDebt(Loan storage loan) internal view returns (uint256) {
        uint256 timePassed = block.timestamp - loan.lastAccrualTime;
        return Interest.calculateCompoundInterest(loan.totalDebtOutstanding, loan.rate, timePassed);
    }
}
