// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ITurnstile } from "./interfaces/ITurnstile.sol";
import { IWCANTO } from "./interfaces/IWCANTO.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { LoanManager } from "./LoanManager.sol";

/**
 * @title Loan Auction House
 * @notice Allows CSR token owners to auction out a loan with their CSR token as collateral.
 * A loan auction is active for 24 hours.
 * Borrower can set a max interest rate above which bids are rejected.
 * Lenders compete by offering a lower interest rate.
 * An auction that ends with no valid bids returns the CSR token to its owner.
 * An auction that ends with a valid bid starts a new loan using a LoanManager contract.
 */
contract LoanAuctionHouse {
    using SafeERC20 for IWCANTO;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   ERRORS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    error NotOwnerNorOperator();
    error InvalidMaxRate();
    error AuctionOver();
    error InvalidBidRate();
    error AuctionInProgress();

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   EVENTS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    event AuctionStarted(
        address indexed creator, uint256 csrTokenId, uint256 principalAmount, uint16 maxRate, uint256 endTime
    );

    event BidCreated(address indexed bidder, uint256 csrTokenId, uint16 bidRate, bool endTimeExtended);

    event AuctionFinalized(uint256 csrTokenId, address indexed bestBidder, uint16 bestRateBid);

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   STRUCTS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    struct Auction {
        address tokenOwner;
        uint256 endTime;
        uint256 principalAmount;
        address bestBidder;
        uint16 bestRateBid;
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   CONSTANTS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /// @notice The minimal duration of an auction
    uint256 public constant AUCTION_DURATION = 24 hours;

    /// @notice The minimal time between when a final bid is placed and when an auction ends
    uint256 public constant LAST_BID_TIME_BUFFER = 15 minutes;

    /// @notice Rates are in 10 basis points units, e.g. 10 is 1%. Limiting rates to 1000%
    uint16 public constant MAX_VALID_RATE = 10_000;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   IMMUTABLES
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /// @notice The Turnstile contract
    ITurnstile public immutable turnstile;

    /// @notice The Wrapped Canto token
    IWCANTO public immutable wCanto;

    /// @notice The contract used to create and manage a loan once an auction is settled
    LoanManager public immutable loanManager;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   STATE VARIABLES
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /// @notice The auction state
    /// @dev CSR tokenId => auction
    mapping(uint256 => Auction) public auctions;

    constructor(ITurnstile turnstile_, IWCANTO wCanto_) {
        turnstile = turnstile_;
        wCanto = wCanto_;
        loanManager = new LoanManager(wCanto_, turnstile_);
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   EXTERNAL TXs
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice Create an auction for anyone to bid to lending to the owner of the provided CSR NFT.
     * @dev This function assumes this was called by the token owner or has approved his contract to transfer the CSR NFT on their behalf
     * @param principalAmount the token amount creator is asking to borrow.
     * @param maxRate the maximum interest rate (APR) the creator will accept.
     * @param csrTokenId the ID of the CSR token to use as collateral.
     */
    function startAuction(uint256 principalAmount, uint16 maxRate, uint256 csrTokenId) public {
        if (maxRate > MAX_VALID_RATE) revert InvalidMaxRate();

        address tokenOwner = turnstile.ownerOf(csrTokenId);

        // Will revert if an auction is already active because NFT is in the auction contract
        // Will revert if owner didn't approve the transfer
        turnstile.transferFrom(tokenOwner, address(this), csrTokenId);

        uint256 endTime = block.timestamp + AUCTION_DURATION;

        Auction storage auction = auctions[csrTokenId];
        auction.tokenOwner = tokenOwner;
        auction.endTime = endTime;
        auction.principalAmount = principalAmount;
        auction.bestBidder = address(0);
        auction.bestRateBid = maxRate + 1;

        emit AuctionStarted(msg.sender, csrTokenId, principalAmount, maxRate, endTime);
    }

    /**
     * @notice Create a new bid to be the lender for the auctioned CSR NFT loan.
     * @param csrTokenId the ID of the CSR token on loan auction msg.sender is bidding on.
     * @param bidRate the interest rate msg.sender is offering as the new best loan terms. rate is in 10 bps units, 15 is 1.5%
     */
    function bid(uint256 csrTokenId, uint16 bidRate) public {
        Auction storage auction = auctions[csrTokenId];
        Auction memory auction_ = auction;

        // This will revert if there's no active auction
        if (auction_.endTime < block.timestamp) revert AuctionOver();

        if (bidRate >= auction_.bestRateBid) revert InvalidBidRate();

        wCanto.safeTransferFrom(msg.sender, address(this), auction_.principalAmount);
        if (auction_.bestBidder != address(0)) {
            // refund previous bidder
            wCanto.safeTransfer(auction_.bestBidder, auction_.principalAmount);
        }

        auction.bestBidder = msg.sender;
        auction.bestRateBid = bidRate;

        bool endTimeExtended = false;
        if (auction_.endTime - block.timestamp < LAST_BID_TIME_BUFFER) {
            auction.endTime = block.timestamp + LAST_BID_TIME_BUFFER;
            endTimeExtended = true;
        }

        emit BidCreated(msg.sender, csrTokenId, bidRate, endTimeExtended);
    }

    /**
     * @notice Finalize the auction on an auctioned CSR NFT loan.
     * If there was at least one bid that met the rate limit, creates a new loan, transfers the CSR NFT
     * to the loan as the collateral, and sends prinicipalAmount tokens to the borrower.
     * Otherwise returns the CSR NFT to its owner.
     * @param csrTokenId the ID of the CSR token on loan auction.
     */
    function finalizeAuction(uint256 csrTokenId) public {
        Auction memory auction = auctions[csrTokenId];

        if (block.timestamp < auction.endTime) revert AuctionInProgress();

        if (auction.bestBidder == address(0)) {
            turnstile.transferFrom(address(this), auction.tokenOwner, csrTokenId);
        } else {
            wCanto.safeTransfer(auction.tokenOwner, auction.principalAmount);
            turnstile.transferFrom(address(this), address(loanManager), csrTokenId);
            loanManager.createLoan(
                csrTokenId, auction.bestBidder, auction.tokenOwner, auction.bestRateBid, auction.principalAmount
            );
        }

        delete auctions[csrTokenId];

        emit AuctionFinalized(csrTokenId, auction.bestBidder, auction.bestRateBid);
    }
}
