// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.0;

import "solmate/tokens/ERC721.sol";
import "./Auction.sol";
import "./Loan.sol";
import "./MintableNFT.sol";

/// @title Factory
/// @notice Responsible for creating new auctions, minting the NFTs after a succesful auction, and creating new loans
contract Factory {
    /*//////////////////////////////////////////////////////////////
                                 ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference to the CSR NFT
    address public immutable csrNft;

    /// @notice Reference to the Auction contract
    Auction public immutable auction;

    /// @notice Reference to the Loan contract
    Loan public immutable loan;

    /// @notice Reference to the Fixed Loan NFT that is minted after a successful auction
    MintableNFT public immutable fixedLoanNft;

    /// @notice Reference to the Borrower NFT that is minted after a successful auction
    MintableNFT public immutable borrowerNft;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Metadata that is associated with an NFT, used when creating the borrowing / fixed loan NFTs
    struct NFTMetadata {
        string name;
        string symbol;
        string baseURI;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuctionCreated(
        address indexed owner,
        uint256 auctionId,
        uint256 csrNftID,
        uint256 principalAmount,
        uint256 maxRate
    );

    event LoanDeployed(
        uint256 indexed auctionId,
        uint256 csrNftId,
        address lender,
        address borrower,
        uint256 principalAmount,
        uint16 rate
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidCsrAddress();
    error InvalidMaxRate(uint16 rate);
    error OnlyAuctionCanDeployLoan();

    /// @notice Set the required addresses
    /// @param _csrNft Address of the CSR NFT
    /// @param _fixedLoanData Metadata for the fixed loan NFT
    /// @param _borrowerData Metadata for the borrower NFT
    constructor(
        address _csrNft,
        NFTMetadata memory _fixedLoanData,
        NFTMetadata memory _borrowerData
    ) {
        if (_csrNft.code.length == 0) revert InvalidCsrAddress();
        csrNft = _csrNft;
        MintableNFT fixedLoan = new MintableNFT(
            _fixedLoanData.name,
            _fixedLoanData.symbol,
            _fixedLoanData.baseURI,
            address(this)
        );
        MintableNFT borrower = new MintableNFT(
            _fixedLoanData.name,
            _borrowerData.symbol,
            _borrowerData.baseURI,
            address(this)
        );
        fixedLoanNft = fixedLoan;
        borrowerNft = borrower;
        loan = new Loan(
            _csrNft,
            address(this),
            address(fixedLoan),
            address(borrower)
        );
        auction = new Auction(address(this), _csrNft, address(loan));
    }

    /// @notice Allows the owner of the CSR NFT to start a new auction
    /// @param _csrNftID Id of the CSR NFT to create the auction for
    /// @param _principalAmount Principal amount of the loan
    /// @param _maxRate Maximum rate (in 10 BPS) that the owner is willing to pay
    function startAuction(
        uint256 _csrNftID,
        uint256 _principalAmount,
        uint16 _maxRate
    ) external returns (uint256 auctionId) {
        if (_maxRate > 10000) revert InvalidMaxRate(_maxRate); // We do not allow rates over 1,000% to avoid errors
        auctionId = auction.createAuction(
            msg.sender,
            _csrNftID,
            _principalAmount,
            _maxRate
        );
        ERC721(csrNft).transferFrom(msg.sender, address(auction), _csrNftID);
        emit AuctionCreated(
            msg.sender,
            auctionId,
            _csrNftID,
            _principalAmount,
            _maxRate
        );
    }

    /// @notice Function that is called by the auction contract after the auction has ended succesfully to deploy the loan and NFTs
    /// @dev The transfer of the NFT ot the loan contract is performed by the auction contract
    /// @param _auctionId ID of the auction, will be used for the fixed loan NFT, borrower NFT, and loan ID
    /// @param _csrNftId ID of the underlying CSR NFT
    /// @param _lender Address of the lender (creator of the auction)
    /// @param _borrower Address of the borrower (winner of the auction)
    /// @param _principalAmount The principal amount of the loan
    /// @param _rate The final rate (in 10 BPS), i.e. the lowest bid during the auction
    function deployLoan(
        uint256 _auctionId,
        uint256 _csrNftId,
        address _lender,
        address _borrower,
        uint256 _principalAmount,
        uint16 _rate
    ) external {
        if (msg.sender != address(auction)) revert OnlyAuctionCanDeployLoan();
        fixedLoanNft.mint(_lender, _auctionId);
        borrowerNft.mint(_borrower, _auctionId);
        loan.createLoan(_auctionId, _csrNftId, _principalAmount, _rate);
        emit LoanDeployed(
            _auctionId,
            _csrNftId,
            _lender,
            _borrower,
            _principalAmount,
            _rate
        );
    }
}
