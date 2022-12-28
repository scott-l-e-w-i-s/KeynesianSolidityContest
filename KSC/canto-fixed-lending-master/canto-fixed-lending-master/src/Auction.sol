// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.0;

import "solmate/tokens/ERC721.sol";
import "solmate/utils/SafeTransferLib.sol";
import "./Factory.sol";

/// @title Auction Contract
/// @notice Manages the auctions of the CSR NFTs
contract Auction {
    /*//////////////////////////////////////////////////////////////
                                 ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice The auctioned NFT collection
    ERC721 public immutable baseNft;

    /// @notice Reference to the Factory
    Factory private immutable factory;

    /// @notice Reference to the Loan contract. CSR NFTs are transferred there after a successful auction
    address private loan;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Data that is associated with one auction
    struct AuctionData {
        /// @notice Creator of the auction that owned the NFT
        address creator;
        /// @notice The auctioned NFT ID
        uint256 nftId;
        /// @notice Principal amount for buying the NFT
        uint256 principalAmount;
        /// @notice Maximum rate that can be bid
        uint16 maxRate;
        /// @notice End of the auction, can be extended by additional bids
        uint40 auctionEnd;
        /// @notice The currently lowest bid rate, type(uint16).max if there was no bid
        uint16 currentBidRate;
        /// @notice Highest bidder at the moment, address(0) if there were no bids
        address highestBidder;
    }

    /// @notice Amount that is claimable (because a higher bid was received or for the owner when the auction was succesful).
    /// The mapping is over all auctions. We use pull payment pattern to avoid griefing
    mapping(address => uint256) public refundAmounts;

    /// @notice Data of all auctions, position in list is auction ID
    AuctionData[] public auctions;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event NewBid(address bidder, uint16 rate);
    event AuctionExtended(uint40 newEndTime);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoBiddingAfterAuctionEndPossible(uint40 auctionEnd);
    error AuctionNotOverYet(uint40 auctionEnd);
    error BidRateMustBeLowerThanCurrentRate(uint16 bidRate, uint16 currentRate);
    error BidRateHigherThanMaxRate(uint16 bidRate);
    error MustPayPrincipalAmount(uint256 biddedAmount);
    error OnlyFactoryCanCreateAuctions();

    /// @notice Set the relevant addresses.
    /// @param _factory Address of the Factory
    /// @param _baseNft Address of the auctioned NFT collection
    /// @param _loan Address of the loan contract. CSR NFTs are transferred there after a successful auction
    constructor(
        address _factory,
        address _baseNft,
        address _loan
    ) {
        factory = Factory(_factory);
        baseNft = ERC721(_baseNft);
        loan = _loan;
    }

    /// @notice Create a new auction, called by the factory
    /// @dev Parameter validation happens in factory and the parameters are not validated here on purpose.
    /// Furthermore, the transfer of the NFT is initiated by the factory
    /// @param _creator Creator of the auction, gets the NFT back if no bids were made
    /// @param _nftId ID of the auctioned NFT
    /// @param _principalAmount Principal amount of the loan
    /// @param _maxRate Maximum rate that can be bid.
    /// @return auctionId ID of the auction
    function createAuction(
        address _creator,
        uint256 _nftId,
        uint256 _principalAmount,
        uint16 _maxRate
    ) external returns (uint256 auctionId) {
        if (msg.sender != address(factory))
            revert OnlyFactoryCanCreateAuctions();
        AuctionData memory auctionData;
        auctionData.creator = _creator;
        auctionData.nftId = _nftId;
        auctionData.principalAmount = _principalAmount;
        auctionData.maxRate = _maxRate;
        auctionData.auctionEnd = uint40(block.timestamp + 24 hours); // No overflow until February 20, 36812
        auctionData.currentBidRate = type(uint16).max;
        auctions.push(auctionData);
        return auctions.length - 1;
        // We emit no event here, as the factory already does so. Use the factory to watch for new auctions
    }

    /// @notice Create a new bid
    /// @dev Uses pull pattern to reimburse current highest bidder, i.e. does not transfer it to him (to avoid griefing)
    /// @param _auctionId ID of the auction to bid for
    /// @param _bidRate The rate to bid
    function bid(uint256 _auctionId, uint16 _bidRate) external payable {
        AuctionData storage auction = auctions[_auctionId]; // Reverts when auctionId does not exist
        uint40 auctionEnd = auction.auctionEnd;
        if (block.timestamp >= auctionEnd)
            revert NoBiddingAfterAuctionEndPossible(auctionEnd);
        if (_bidRate >= auction.maxRate)
            revert BidRateHigherThanMaxRate(_bidRate);
        uint16 currentBidRate = auction.currentBidRate;
        if (_bidRate >= currentBidRate)
            revert BidRateMustBeLowerThanCurrentRate(_bidRate, currentBidRate);
        uint256 principalAmount = auction.principalAmount;
        if (msg.value != principalAmount)
            revert MustPayPrincipalAmount(msg.value);
        address highestBidder = auction.highestBidder;
        if (highestBidder != address(0)) {
            // Instead of sending the value to the current highest bidder, we store it in refundAmounts such that griefing the bid is not possible
            refundAmounts[highestBidder] += principalAmount; // Note that we need to increase the value because there can be multiple failed bids for a user.
        }
        auction.highestBidder = msg.sender; // It is possible that the current highest bidder bids again with a lower rate, but there is no reason to prevent that
        auction.currentBidRate = _bidRate;
        emit NewBid(msg.sender, _bidRate);

        // Cannot underflow because of end time validation
        if (auctionEnd - block.timestamp <= 15 minutes) {
            uint40 newEnd = uint40(block.timestamp + 15 minutes);
            auction.auctionEnd = newEnd;
            emit AuctionExtended(newEnd);
        }
    }

    /// @notice Finalize an auction. Can be called by anyone after the auction is over.
    /// If there were no bids, transfers the NFT back to the owner.
    /// @param _auctionId ID of the auction to finalize
    function finalizeAuction(uint256 _auctionId) external {
        AuctionData storage auction = auctions[_auctionId];
        uint40 auctionEnd = auction.auctionEnd;
        if (block.timestamp < auctionEnd) revert AuctionNotOverYet(auctionEnd);
        auction.auctionEnd = type(uint40).max; // Ensure that auction can only be finalized once (even if NFT is later again in this contract)
        address highestBidder = auction.highestBidder;
        uint256 nftId = auction.nftId;
        if (highestBidder == address(0)) {
            // There were no bids
            baseNft.transferFrom(address(this), auction.creator, nftId);
        } else {
            refundAmounts[auction.creator] += auction.principalAmount; // We also increase refundAmounts here to avoid griefing / failed transfers caused by the creator
            // We transfer the NFT directly to the loan contract (instead of first to the factory) to save gas
            baseNft.transferFrom(address(this), loan, nftId);
            factory.deployLoan(
                _auctionId,
                nftId,
                auction.creator,
                highestBidder,
                auction.principalAmount,
                auction.currentBidRate
            );
        }
    }

    /// @notice Function to refund funds to users whose bid was unsuccesful or to get principal as the creator when the bid is over
    /// @dev Refunds across all auctions, no ID is provided
    function getFunds() external {
        uint256 refundAmount = refundAmounts[msg.sender];
        refundAmounts[msg.sender] = 0; // Set first to 0 to avoid reentering and claiming again
        SafeTransferLib.safeTransferETH(msg.sender, refundAmount);
    }
}
