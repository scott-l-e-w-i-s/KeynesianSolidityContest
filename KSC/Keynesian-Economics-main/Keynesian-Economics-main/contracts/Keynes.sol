// SPDX-License-Identifier: GPL-3
pragma solidity 0.8.17;

import {IERC721} from "@oz/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@oz/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@oz/security/ReentrancyGuard.sol";
import {ITurnstile} from "../interfaces/canto/ITurnstile.sol";

import {MintableNFT} from "./deps/MintableNFT.sol";
import {ABDKMath64x64} from "./libs/ABDKMath64x64.sol";


/// @title Keynes
/// @author REDACTED
/// @notice 
/// Using `ABDKMath64x64` see their license
/// Lock your CRS_NFT for a principal amount
/// Lender receives the interest gained by CRS_NFT
/// Debt and Credit positions are issued as NFTs, allowing further composability
/// This contract itself also receives a CRS_NFT
/// Above are listed a few notes on what's next to improve the codebase, and get it ready for launch
/// Minor optimizations are added, however any additional should be performed after reaching high coverage
/// @notice We have a counter for auctions, which maps out to loans
/// This makes it easier to track everything as succesful auctions, will always have their loan with the same Id
contract Keynes is IERC721Receiver {
    using ABDKMath64x64 for int128;

    // NOTE: See below notes for packing refactorings, which I wouldn't do until we have test coverage
    struct Bid {
        uint256 rate; // NOTE: If 10 bp 2^16 is enough
        address receiver;
    }
    struct Auction {
        Bid activeBid;
        uint256 endTime; // 2^64 is way more than enough
        uint256 maxRate; // 2^32 is way more than enough || NOTE: If 10 bp 2^16 is enough
        uint256 csrNftID;
        uint256 principalAmount; // Assuming canto 10^27 (1 Billion max) | 2^128 is fine
        address creator;
        bool settled;
    }

    struct Loan {
        uint256 debtRemaining; // Assuming canto 10^27 (1 Billion max) | 2^128 is fine
        uint256 lastAccrualTimestamp; // 2^64 is way more than enough
        uint256 rate; // 2^32 is way more than enough || NOTE: If 10 bp 2^16 is enough
        uint256 payableAmount; // Assuming canto 10^27 (1 Billion max) | 2^128 is fine
        uint256 csrNftID;
        bool settled;
    }

    uint256 constant SECONDS_PER_YEAR = 365.25 days;

    uint256 constant AUCTION_DURATION = 24 hours;

    uint256 constant ONE_ETH = 1 ether;

    /// @dev We use counter for IDs
    ///   We match id between auction and loans
    ///   This means some loans will not exist, but it's best ux to match auction and loan id
    ///   e.g. for a succesful Auction, retrieve the loan via loans[auctionId]
    ///   This maps out to the FIXED_LOAN_NFT and BORROWER_NFT
    ///   To get info on the Auction just do auctions[FIXED_LOAN_NFT.id]
    uint256 public counter;

    // NFTs from Canto for Claiming Contract Secured Revenue
    ITurnstile immutable public CSR_NFT;

    /// @dev This contract will deploy these two NFT Contracts and be the immutable owner
    /// This is used to mean NFTs of the id that matches with the loanId (which also matches with auctions for convenience)
    MintableNFT immutable public FIXED_LOAN_NFT;
    MintableNFT immutable public BORROWER_NFT;

    /// @dev Given an ID return the info for the auction
    mapping(uint256 => Auction) public auctions;

    /// @dev Given an ID return the info for the loans
    mapping(uint256 => Loan) public loans;

    /// @notice We set from 1 to avoid triggering gas refunds to keep it cheaper
    uint256 private receivingID = 1;

    /// @notice Very generous stipend for one SSTORE
    uint256 private constant TRANSFER_GAS = 24_000;

    constructor(ITurnstile csrfNft) {
        CSR_NFT = csrfNft;

        // Register this contract as well
        // Send NFT to deployer
        csrfNft.register(msg.sender);

        FIXED_LOAN_NFT = new MintableNFT("Keynes Fixed Loan", "kFL");
        BORROWER_NFT = new MintableNFT("Keynes Borrower", "kB");
    }

    /// === Auction Factory === ///

    /// @dev Start a new auction for a given NFT you hold
    /// @notice Must hold the CRS_NFT or it will revert
    /// @param principalAmount - The amount you'd like to receive from a lender
    /// @param maxRate - The maximum interest rate you're willing to pay (lower = cheaper for you)
    ///   The interest is expressed in BPS
    /// @param csrNftID - The Id of the CRS_NFT you wish to use as collateral
    /// @return The ID of the auction created (which is a counter that always increments)
    function startAuction(
        uint256 principalAmount,
        uint256 maxRate,
        uint256 csrNftID
    ) external returns (uint256) {
        // Increment internal Id
        // We align Auctions and Loans to have matching Ids for convenience
        // NOTE: Because it's pre-increment, Id 0 is never used
        uint256 cachedAuctionId;
        unchecked {
            cachedAuctionId = ++counter;
        }

        // create a new auction object with auction endtime in 24 hours
        uint256 endTime = block.timestamp + AUCTION_DURATION;

        // Create the auction here
        auctions[cachedAuctionId] = Auction({
            activeBid: Bid({rate: maxRate, receiver: address(0)}),
            endTime: endTime,
            maxRate: maxRate,
            csrNftID: csrNftID,
            principalAmount: principalAmount,
            creator: msg.sender,
            settled: false
        });

        // Send the NFT to this
        CSR_NFT.safeTransferFrom(msg.sender, address(this), csrNftID);

        return cachedAuctionId;
    }

    /// === Auction === ///

    /// @dev Given an auctionId, bid on it with the specified rate
    /// @notice Must offer a lower rate than current one
    ///   Refunds the previous bidder, you must also send the principal via msg.value
    /// @param auctionId - The id of the auction you wish to bid on
    /// @param bidRate - The interest rate you wish to bid (lower = less interest)
    ///     The interest is expressed in BPS
    function bid(uint256 auctionId, uint256 bidRate) external payable {
        Auction storage auctionPointer = auctions[auctionId];

        uint256 cachedPrincipalAmount = auctionPointer.principalAmount;

        require(msg.value == cachedPrincipalAmount, "Send exact amount");

        uint256 cachedendTime = auctionPointer.endTime;
        // verify auction not over
        require(cachedendTime > block.timestamp, "Expired");

        // verify bidRate is less than current bidRate
        // NOTE: Check this first as it's more likely for revert
        require(bidRate < auctionPointer.activeBid.rate, "Bid is not better");

        // verify bidRate is less than or equal to maxRate
        require(bidRate <= auctionPointer.maxRate, "Bid is too high");

        // if within last 15 minutes, auctionEndTime = current timestap + 15 min
        uint256 maxNewTime = block.timestamp + 15 minutes;
        if (maxNewTime > cachedendTime) {
            auctionPointer.endTime = maxNewTime;
        }

        // Cache Old bidder for refund
        address refundAddres = auctionPointer.activeBid.receiver;

        // Update Bidder
        auctionPointer.activeBid.receiver = msg.sender;
        auctionPointer.activeBid.rate = bidRate;

        // transfer principalAmount from bidder to auction object
        // No need for this as we're denominated in ONE_ETH

        // transfer prior bidders principalAmount back to them
        if(refundAddres != address(0)) {
            (bool success, ) = refundAddres.call{
                gas: TRANSFER_GAS,
                value: cachedPrincipalAmount
            }("");
            require(success, "Error in Transfer");
        }
    }

    /// @dev Given an auctionId, settle or cancel the auction
    /// @param auctionId - the id of the auction
    /// @notice if No bids, it will send back the CRS_NFT
    ///   If there are bids it will lock the CRS_NFT
    ///   Then create a FIXED_LOAN_NFT and a BORROWER_NFT
    ///   It will then setup a loan object to be interactive with
    /// @return 0 on failure, the loanId == auctionId on success
    function finalizeAuction(uint256 auctionId) external returns (uint256) {
        Auction storage auctionPointer = auctions[auctionId];

        // verify auction is over
        require(block.timestamp > auctionPointer.endTime, "Not over yet");

        // e.g. use Id = 1 to mean it's done so we save a slot
        require(!auctionPointer.settled, "Already settled");
        auctionPointer.settled = true;

        // if no bids, send csrNFT back to auction starter
        // Saves gas if we create the Loan
        uint256 cachedAuctionRate = auctionPointer.activeBid.rate;
        if (cachedAuctionRate == 0) {
            // Just refund
            CSR_NFT.safeTransferFrom(
                address(this),
                auctionPointer.creator,
                auctionPointer.csrNftID
            );

            return 0;
        } else {
            // else transfer principalAmount to auction creator
            uint256 cachedPrincipalAmount = auctionPointer.principalAmount;

            // Create Loan for this auction
            loans[auctionId] = Loan({
                debtRemaining: cachedPrincipalAmount,
                lastAccrualTimestamp: block.timestamp,
                rate: cachedAuctionRate,
                payableAmount: 0,
                csrNftID: auctionPointer.csrNftID,
                settled: false
            });

            // NOTE: Can reenter, but no state changes after this point
            address cachedCreator = auctionPointer.creator;
            (bool success, ) = payable(cachedCreator).call{
                gas: TRANSFER_GAS,
                value: cachedPrincipalAmount
            }("");
            require(success, "Error in Transfer");

            // mint FixedLoanNFT to auction winner
            FIXED_LOAN_NFT.mint(auctionPointer.activeBid.receiver, auctionId);
            // mint borrowerNFT to auction starter
            BORROWER_NFT.mint(cachedCreator, auctionId);

            // Return auctioId as we use the same counters for the Loans
            return auctionId;
        }
    }

    /// === Loan === ///

    /// @dev Given a loanId, use claimable to repay debt and accrue to payable
    /// @param loanId - for which loan do you wish to repayWithClaimable
    /// @notice Reduces debt by same amount claimed, adds that balance to pyableAmount
    /// @return The amount claimed
    function repayWithClaimable(uint256 loanId) external returns (uint256) {
        // accrue interest on debt
        Loan storage loanPointer = loans[loanId];

        _accrueInterest(loanPointer);

        // Set the receiving balance to the current AuctionID
        receivingID = loanId + 1;

        uint256 cachedCsrNftID = loanPointer.csrNftID;

        uint256 claimable = CSR_NFT.balances(cachedCsrNftID);

        uint256 cachedDebtRemaining = loanPointer.debtRemaining;

        uint256 maximumClaimable = min(claimable, cachedDebtRemaining);

        // End early if nothing to claim
        if (maximumClaimable == 0) {
            return 0;
        }

        // accrue claimed amount to the payable of FixedLoanNFT
        // decrement total debt outstanding by claimed amount

        // Reduce the debt
        unchecked {
            // Unchecked safe per the check above
            loanPointer.payableAmount += maximumClaimable;
            loanPointer.debtRemaining = cachedDebtRemaining - maximumClaimable;
        }

        // Claim maximumClaimable
        // Safe because we know implementation and they will not re-enter
        // NOTE: alternative is to increase balance of loan based on the receiving ID set above
        CSR_NFT.withdraw(
            cachedCsrNftID,
            payable(address(this)),
            maximumClaimable
        );

        // Set back to 0 so we can't receive
        receivingID = 1;

        return maximumClaimable;
    }

    /// @dev Given a loanId, repay with msg.value
    /// @notice If you send too much, it will refund you the remaining amount
    /// @param loanId The id of the loan to repay
    function repayWithExternal(uint256 loanId) external payable {
        // call ._accrueInterest
        Loan storage loanPointer = loans[loanId];

        _accrueInterest(loanPointer);

        uint256 cachedDebtRemaining = loanPointer.debtRemaining;
        uint256 maximumClaimable = min(msg.value, cachedDebtRemaining);

        // decrement total debt outstanding by amount
        // accrue claimed amount to payable
        unchecked {
            // Unchecked safe per the check above
            loanPointer.payableAmount += maximumClaimable;
            loanPointer.debtRemaining = cachedDebtRemaining - maximumClaimable;
        }

        // We may need to refund value, we could revert if they send too much also, but this is gentler
        if (msg.value > maximumClaimable) {
            unchecked {
                (bool success, ) = msg.sender.call{
                    gas: TRANSFER_GAS,
                    value: (msg.value - maximumClaimable)
                }("");
                require(success, "Error in Transfer");
            }
        }
    }

    /// @dev Given a loanId, for which you hold the FIXED_LOAN_NFT, withdraw an amount of payable earned
    /// @notice If you set amount to 0, it will send max
    /// @notice if you set amount to more than what you can claim, it will also claimmax
    /// @param loanId - The id for which payable amount you want to claim
    /// @param amount - The amount to claim
    /// @return The Amount withdrawn
    function withdrawPayable(
        uint256 loanId,
        uint256 amount
    ) external returns (uint256) {
        // verify withdrawer is owner of fixedLoanNFT
        require(FIXED_LOAN_NFT.ownerOf(loanId) == msg.sender, "Only Loan NFT Holder");

        Loan storage loanPointer = loans[loanId];

        // withdraw min(amount,payable) if amount was passed. withdraw total payable if not passed
        uint256 wholeAmount = loanPointer.payableAmount;

        if (wholeAmount == 0) {
            // End early if nothing to withdraw
            return 0;
        }

        if (amount == 0) {
            // We send the whole payable
            loanPointer.payableAmount = 0; // Equivalent to delete, no gas savings

            (bool success, ) = msg.sender.call{
                gas: TRANSFER_GAS,
                value: wholeAmount
            }("");
            require(success, "TransferFailed");
        } else {
            // Send min
            uint256 toSend = min(amount, wholeAmount);

            loanPointer.payableAmount -= toSend;

            (bool success, ) = msg.sender.call{
                gas: TRANSFER_GAS,
                value: wholeAmount
            }("");
            require(success, "TransferFailed");
        }

        return wholeAmount;
    }

    /// @dev Given a loanID, for which you hold the BORROWER_NFT, if no more debt is remaining, withdraw the CRS_NFT
    /// @notice You can only call this if the debt is 0 and you hold BORROWER_NFT
    /// @param loanId Id for the loan for which you wish to withdraw the CRS_NFT
    /// @return the Id of the CRS_NFT you were sent back
    function withdrawNFT(uint256 loanId) external returns (uint256) {
        // verify caller owns borrowerNFT
        require(
            BORROWER_NFT.ownerOf(loanId) == msg.sender,
            "Only owner of Borrower"
        );

        Loan storage loanPointer = loans[loanId];

        // verify NFTwithdrawable = True
        require(loanPointer.debtRemaining == 0, "Must be paid");

        require(!loanPointer.settled, "Already Settled");
        loanPointer.settled = true;

        // send csrNFT to caller
        uint256 idToSend = loanPointer.csrNftID;
        CSR_NFT.safeTransferFrom(address(this), msg.sender, idToSend);
        return idToSend;
    }

    /// @dev Given a pointer to a loan, accrue the interest
    /// @notice Will skip if 0 debt and if no time has passed
    ///   Uses `getNewDebt` to calculate the amounts
    function _accrueInterest(Loan storage loan) internal {
        // timePassed = current timestamp - last accrual timestap
        // debtMultiplier = exp(rate * timepassed)
        // total debt outstanding = total debt outstanding * debtMultipler

        if (loan.debtRemaining == 0) {
            return; // No point in accruing if no debt left
        }

        uint256 timePassed = block.timestamp - loan.lastAccrualTimestamp;
        if (timePassed == 0) {
            return; // No point in accruing if no time has passed
        }

        uint256 newDebt = getNewDebt(loan.debtRemaining, timePassed, loan.rate);

        // Update loan
        loan.debtRemaining = newDebt;
        loan.lastAccrualTimestamp = block.timestamp;
    }

    /// @dev Given a debt amount, time elapsed and interestRate (in BPS), calculates the new Debt
    /// @notice Uses `ABDKMath64x64` to perform e^exp and then returns a uin256
    /// @param debt - Amount of debt
    /// @param timeElapsed - Seconds since last accrue
    /// @param interestRate - Interest rate, in BPS
    /// @return The new debt
    function getNewDebt(
        uint256 debt,
        uint256 timeElapsed,
        uint256 interestRate
    ) public returns (uint256) {
        // Wrap values so we can use the library
        int128 wrappedDebtPlaceholder = ABDKMath64x64.fromUInt(ONE_ETH);
        int128 wrappedInterest = ABDKMath64x64.fromUInt(interestRate);
        int128 wrappedTime = ABDKMath64x64.fromUInt(timeElapsed);
        int128 wrappedSecondsPerYear = ABDKMath64x64.fromUInt(SECONDS_PER_YEAR);
        int128 wrappedDivisor = ABDKMath64x64.fromUInt(10_000);

        // Apply formula to get multiplier
        int128 newExpDebt = wrappedDebtPlaceholder.mul(
            ABDKMath64x64.exp(
                wrappedInterest.mul(wrappedTime).div(wrappedSecondsPerYear).div(
                    wrappedDivisor
                )
            )
        );

        // Multiply by exponent and then divide by oneEth as we used ONE_ETH in place of debt
        // ac * b  / c = a * b
        debt = (debt * newExpDebt.toUInt()) / ONE_ETH;
        return debt;
    }

    /// === MISC === ///

    /// @notice So we can receive NFTs using safeTransfer
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Receive only when claiming, for specific ID
    receive() external payable {
        // Only accept funds from CSR
        // Technically someone can self-destruct transfer but we can live with that
        require(msg.sender == address(CSR_NFT), "Only from CSR");
        require(receivingID > 1, "No Receiving ID Set");
    }

    /// === Internal Generic Functions === //

    /// @dev Given two number return the minimum
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? b : a;
    }
}
