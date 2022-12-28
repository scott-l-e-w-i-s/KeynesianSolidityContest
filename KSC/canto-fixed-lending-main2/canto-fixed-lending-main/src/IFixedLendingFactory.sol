// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface IFixedLendingFactory {
    error InvalidMaxRate();
    error NotAuthorized();
    error InvalidAddress();

    event LogAuctionCreated(
        address indexed fixedLendingClone,
        uint256 indexed csrNFTId,
        uint256 principalAmount,
        uint256 maxRate
    );

    function startAuction(uint256 principalAmount, uint256 maxRate, uint256 csrNFTId) external returns (address);
}
