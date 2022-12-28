// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface IFixedLending {
    /* ---------------------------------- Enums --------------------------------- */

    enum BidValidation {
        MAX_RATE,
        CURRENT_BID_RATE
    }

    enum AuctionValidation {
        AUCTION_ENDED,
        AUCTION_ONGOING
    }

    enum Lifecycle {
        AUCTION_LIVE,
        LOAN_OUTSTANDING,
        LOAN_REPAID,
        CLOSED
    }

    /* --------------------------------- Errors --------------------------------- */

    error InvalidAuctionWindow(AuctionValidation);
    error BidTooHigh(BidValidation);
    error DebtOutstanding();
    error NotAuthorized();

    /* --------------------------------- Events --------------------------------- */

    event LogAuctionFinalized();
    event LogNewBid(address indexed bidder, uint256 bidRate);
    event LogCollateralWithdrawn(address indexed to);
    event LogPayableWithdrawn(address indexed to, uint256 amount);

    /* --------------------------------- Auction -------------------------------- */

    function bid(uint256 bidRate) external;

    function finalizeAuction() external;

    /* ---------------------------------- Loan ---------------------------------- */

    function repayWithClaimable() external;

    function repayWithExternal(uint256 amount) external;

    function withdrawPayable() external returns (uint256);

    function withdrawPayable(uint256 amount) external returns (uint256);

    function withdrawNFT() external;
}
