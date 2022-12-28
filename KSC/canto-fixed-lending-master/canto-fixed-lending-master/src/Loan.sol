// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.0;

import "solmate/tokens/ERC721.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/SignedWadMath.sol";
import "solmate/utils/FixedPointMathLib.sol";
import "./interface/ITurnstile.sol";
import "./MintableNFT.sol";

/// @title Loan Contract
/// @notice Manages loans that are backed by CSR NFTs. Authentication of borrower / lender is done with NFTs, so these positions can be transferred
contract Loan {
    int256 private constant DAYS_WAD = 365250000000000000000; // 365.25 as wad (with 18 decimals)

    /*//////////////////////////////////////////////////////////////
                                ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference to the Factory. Only the factory is allowed to create new loans
    address private immutable factory;

    /// @notice Reference to the CSR NFT
    ITurnstile public immutable csrNft;

    /// @notice Reference to the Fixed Loan NFT, used for authenticating the lender
    ERC721 public immutable fixedLoanNft;

    /// @notice Reference to the Borrower NFT, used for authenticating the borrower
    ERC721 public immutable borrowerNft;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Date that is associated with a loan
    struct LoanData {
        /// @notice The CSR NFT ID that is associated with the loan
        uint256 csrNftId;
        /// @notice The accrued debt
        uint256 accruedDebt;
        /// @notice Amount that is withdrawable by the owner of the fixed loan NFT
        uint256 withdrawable;
        /// @notice The interest rate (in 10 BPS), stored with 18 decimals. Stored as int to avoid casting for the rate calculations
        int256 rateWad;
        /// @notice Last time interest was accrued
        uint40 lastAccrued;
    }

    /// @notice Mapping containing the informations about the loans
    mapping(uint256 => LoanData) public loans;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ReducedDebtWithClaimable(
        uint256 indexed loanId,
        address caller,
        uint256 claimed,
        uint256 newAccrued,
        uint256 newWithdrawable
    );
    event ReducedDebtWithExternal(
        uint256 indexed loanId,
        uint256 repaid,
        uint256 newAccrued,
        uint256 newWithdrawable
    );
    event WithdrawnPayable(
        uint256 indexed loanId,
        uint256 amount,
        uint256 newWithdrawable
    );
    event NFTWithdrawn(
        uint256 indexed loanId,
        uint256 indexed csrNftId,
        address caller
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyBorrower();
    error OnlyLender();
    error OnlyFactoryCanCreateLoans();
    error TooMuchTooWithdrawRequested();
    error AccruedDebtRemaining(uint256 accruedDebt);

    /// @notice Modifier for functions that are only callable by the owner of the borrower NFT
    modifier onlyBorrower(uint256 _loanId) {
        if (msg.sender != borrowerNft.ownerOf(_loanId)) revert OnlyBorrower();
        _;
    }

    /// @notice Modifier for functions that are only callable by the owner of the borrower NFT
    modifier onlyLender(uint256 _loanId) {
        if (msg.sender != fixedLoanNft.ownerOf(_loanId)) revert OnlyLender();
        _;
    }

    /// @notice Sets all the addresses and the principal amount which is fixed across all loans
    /// @param _csrNft The address of the CSR NFT
    /// @param _factory The address of the Factory
    /// @param _fixedLoanNft The address of the fixed loan NFT
    /// @param _borrowerNft The address of the _borrowerNft
    constructor(
        address _csrNft,
        address _factory,
        address _fixedLoanNft,
        address _borrowerNft
    ) {
        csrNft = ITurnstile(_csrNft);
        factory = _factory;
        fixedLoanNft = ERC721(_fixedLoanNft);
        borrowerNft = ERC721(_borrowerNft);
    }

    /// @notice Create a new loan for the given CSR NFT with the given rate
    /// @dev Only callable by the factory, which also transfers the NFT to this contract when creating the loan
    /// @param _loanId ID of the loan to create. Corresponds to the ID of the fixed loan / borrower NFT that is given to the lender / borrower
    /// @param _csrNftId ID of the CSR NFT that underlies this loan
    /// @param _principalAmount The principal amount of the loan
    /// @param _rate The interest rate of the loan. Currently determined in an auction, but other ways would be possible
    function createLoan(
        uint256 _loanId,
        uint256 _csrNftId,
        uint256 _principalAmount,
        uint16 _rate
    ) external {
        if (msg.sender != factory) revert OnlyFactoryCanCreateLoans();
        LoanData memory loanData;
        loanData.accruedDebt = _principalAmount;
        loanData.csrNftId = _csrNftId;
        loanData.lastAccrued = uint40(block.timestamp);
        // Provided rate is in 10 BPS, we therefore divide by 1,000
        loanData.rateWad = toWadUnsafe(_rate) / 1_000; // No overflow possible because _rate is uint16
        loans[_loanId] = loanData;
        // We emit no event here, as the factory already does so. Use the factory to watch for new loans
    }

    /// @notice Use the revenue from the CSR NFT to repay the accrued debt.
    /// @dev Generally uses the whole claimable amount, but if more than the remaining debt is claimable, only the remaining debt is claimed.
    /// @dev Callable by anyone, e.g. the borrower or the lender
    /// @param _loanId ID of the loan to claim for
    function repayWithClaimable(uint256 _loanId) external {
        _accrueInterest(_loanId);
        LoanData storage loan = loans[_loanId]; // Reverts for non-existing loans
        uint256 tokenId = loan.csrNftId;
        uint256 toClaim = csrNft.balances(tokenId);
        uint256 debtOutstanding = loan.accruedDebt;
        if (toClaim > debtOutstanding) {
            toClaim = debtOutstanding;
        }
        uint256 claimed = csrNft.withdraw(
            tokenId,
            payable(address(this)),
            toClaim
        ); // claimed should always be equal to toClaim because of the logic above
        uint256 newAccrued = loan.accruedDebt - claimed;
        uint256 newWithdrawable = loan.withdrawable + claimed;
        loan.accruedDebt = newAccrued;
        loan.withdrawable = newWithdrawable;
        emit ReducedDebtWithClaimable(
            _loanId,
            msg.sender,
            claimed,
            newAccrued,
            newWithdrawable
        );
    }

    /// @notice Pay back the loan directly
    /// @dev If the borrower pays more than the outstanding debt, he is reimbursed the difference
    /// @dev Only callable by the borrower
    /// @param _loanId ID of the loan to repay
    function repayWithExternal(uint256 _loanId)
        external
        payable
        onlyBorrower(_loanId)
    {
        _accrueInterest(_loanId);
        LoanData storage loan = loans[_loanId];
        uint256 debtOutstanding = loan.accruedDebt;
        if (msg.value > debtOutstanding) {
            // Reimburse user if he paid too much
            loan.accruedDebt = 0;
            uint256 newWithdrawable = loan.withdrawable + debtOutstanding;
            loan.withdrawable = newWithdrawable;
            SafeTransferLib.safeTransferETH(
                msg.sender,
                msg.value - debtOutstanding
            );
            emit ReducedDebtWithExternal(
                _loanId,
                debtOutstanding,
                0,
                newWithdrawable
            );
        } else {
            uint256 newAccrued = loan.accruedDebt - msg.value;
            uint256 newWithdrawable = loan.withdrawable + debtOutstanding;
            loan.accruedDebt = newAccrued;
            loan.withdrawable += newWithdrawable;
            emit ReducedDebtWithExternal(
                _loanId,
                msg.value,
                newAccrued,
                newWithdrawable
            );
        }
    }

    /// @notice Withdraw paid back debt / interest as lender
    /// @dev If the lender requests more than what is withdrawable, the function reverts. Use 0 to request everything
    /// @dev Only callable by the lender
    /// @param _amount Amount to withdraw. 0 if everything should be withdrawn
    /// @param _loanId ID of the loan to withdraw from
    function withdrawPayable(uint256 _loanId, uint256 _amount)
        external
        onlyLender(_loanId)
    {
        LoanData storage loan = loans[_loanId];
        uint256 withdrawable = loan.withdrawable;
        if (_amount > withdrawable) {
            // We could also only send withdrawable in this case.
            // But this might be confusing for integrations that expect to receive the requested amount when it is > 0
            revert TooMuchTooWithdrawRequested();
        }
        if (_amount == 0) {
            _amount = withdrawable;
        }
        uint256 newWithdrawable = loan.withdrawable - _amount;
        loan.withdrawable = newWithdrawable;
        SafeTransferLib.safeTransferETH(msg.sender, _amount);
        emit WithdrawnPayable(_loanId, _amount, newWithdrawable);
    }

    /// @notice Withdraw the CSR NFT after the loan was paid back fully
    /// @dev Only callable by the borrower after the loan was fully repaid, i.e. accruedDebt is 0
    /// @param _loanId ID of the loan from which the CSR NFT should be withdrawn
    function withdrawNFT(uint256 _loanId) external onlyBorrower(_loanId) {
        LoanData storage loan = loans[_loanId];
        uint256 accruedDebt = loan.accruedDebt;
        if (accruedDebt != 0) revert AccruedDebtRemaining(accruedDebt);
        uint256 csrNftId = loan.csrNftId;
        csrNft.transferFrom(address(this), msg.sender, csrNftId);
        // We do not burn the borrower NFT when the loan is fully repaid, but it does no longer have any use within the contract
        emit NFTWithdrawn(_loanId, csrNftId, msg.sender);
    }

    /// @notice Internal function to accrue interest
    /// @dev Should be called before all modifications to accruedDebt
    /// @param _loanId ID of the loan to accrue interest for
    function _accrueInterest(uint256 _loanId) internal {
        LoanData storage loan = loans[_loanId];
        uint256 secondsPassed = loan.lastAccrued - block.timestamp;
        if (secondsPassed == 0) {
            return;
        }
        int256 daysPassedWad = toDaysWadUnsafe(secondsPassed);
        int256 yearsPassedWad = wadDiv(daysPassedWad, DAYS_WAD);
        uint256 debtMultiplerWad = uint256(
            wadExp(wadMul(yearsPassedWad, loan.rateWad))
        ); // exp(r * Δt). Cast to uint is safe here because result is always positive
        loan.accruedDebt = FixedPointMathLib.mulWadUp(
            loan.accruedDebt,
            debtMultiplerWad
        ); // Divides by WAD to bring result back to original unit
        loan.lastAccrued = uint40(block.timestamp);
    }
}
