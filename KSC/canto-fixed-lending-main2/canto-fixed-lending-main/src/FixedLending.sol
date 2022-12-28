// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { IFixedLending } from "src/IFixedLending.sol";
import { Turnstile } from "src/vendor/Turnstile.sol";
import { Clone } from "clones-with-immutable-args/Clone.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { BaseERC721 } from "src/BaseERC721.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solmate/utils/SafeCastLib.sol";
import { Math } from "openzeppelin/utils/math/Math.sol";

interface WETH9 {
    function deposit() external payable;
}

contract FixedLending is Clone, IFixedLending {
    using SafeTransferLib for ERC20;

    /* --------------------------------- Storage -------------------------------- */

    uint256 public debtOutstanding;
    uint256 public lastAccrual;
    // Pack bid with bidder.
    uint32 public currentBid;
    address public currentBidder;
    uint256 public auctionOverTimeEnd;

    /* --------------------------------- Getters -------------------------------- */

    function getTurnstile() external pure returns (Turnstile) {
        return _getTurnstile();
    }

    /* --------------------------------- Auction -------------------------------- */

    /**
     * @param bidRate interest rate in 10 bps increments, e.g. bidRate of 2 is 20 bps annual interest.
     */
    function bid(uint256 bidRate) external {
        // No bids on or after auction end.
        if (block.timestamp >= _getAndUpdateAuctionEnd()) {
            revert InvalidAuctionWindow(AuctionValidation.AUCTION_ENDED);
        }
        // Bids must be below max.
        if (bidRate > _getMaxRate()) {
            revert BidTooHigh(BidValidation.MAX_RATE);
        }
        // Bid must improve on previous bid.
        uint256 previousBid = uint256(currentBid);
        if (previousBid != 0 && bidRate >= previousBid) {
            revert BidTooHigh(BidValidation.CURRENT_BID_RATE);
        }

        // Cache currentBidder.
        address previousBidder = currentBidder;

        // Effects.
        currentBidder = msg.sender;
        currentBid = SafeCastLib.safeCastTo32(bidRate);

        // Save gas by only transferring 1x per transaction.
        if (previousBidder == address(0)) {
            // Transfer to the contract.
            _getWCanto().safeTransferFrom(msg.sender, address(this), _getPrincipalAmount());
        } else {
            // Invariant test.
            assert(_getWCanto().balanceOf(address(this)) >= _getPrincipalAmount());
            // Refund previous bidder.
            _getWCanto().safeTransferFrom(msg.sender, previousBidder, _getPrincipalAmount());
        }

        emit LogNewBid(msg.sender, bidRate);
    }

    /**
     * @dev NFT burning / transfer prevents calling 2x.
     */
    function finalizeAuction() external {
        if (_getAuctionEnd() > block.timestamp) {
            revert InvalidAuctionWindow(AuctionValidation.AUCTION_ONGOING);
        }

        if (currentBid == 0) {
            // No bids, return to original owner.
            _getTurnstile().transferFrom(address(this), _getCSROwner(), _getCSRId());
            // And burn unused tokens.
            _getFixedLoanNFT().burn(_getCSRId());
            _getBorrowerNFT().burn(_getCSRId());
        } else {
            // Cache
            uint256 csrId = _getCSRId();
            uint256 principalAmount = _getPrincipalAmount();
            address csrOwner = _getCSROwner();
            // Update Contract state.
            lastAccrual = block.timestamp;
            debtOutstanding = principalAmount;

            // principalAmount goes to CSROwner.
            _getWCanto().safeTransfer(csrOwner, principalAmount);
            // Lender Token.
            _getFixedLoanNFT().transferFrom(address(this), currentBidder, csrId);
            // Borrower Token.
            _getBorrowerNFT().transferFrom(address(this), csrOwner, csrId);
        }

        emit LogAuctionFinalized();
    }

    /* ---------------------------------- Loan ---------------------------------- */

    function repayWithClaimable() external {
        // Accrue.
        uint256 totalDebt = _accrueInterest();

        // Cache variables.
        uint256 csrId = _getCSRId();
        Turnstile turnstile = _getTurnstile();
        uint256 amountToPay = Math.min(totalDebt, turnstile.balances(csrId));

        // Pull in canto.
        amountToPay = turnstile.withdraw(csrId, payable(address(this)), amountToPay);

        // Update debt so interest calculated on remaining debt.
        _decrementDebtOutstanding(amountToPay);

        // Wrap and pay to contract as payable of FixedLoanNFT.
        WETH9(address(_getWCanto())).deposit{ value: amountToPay }();
    }

    /**
     * @param amount wad amount of wrapped canto to repay.
     */
    function repayWithExternal(uint256 amount) external {
        uint256 totalDebt = _accrueInterest();
        // Don't overpay.
        uint256 amountToPay = Math.min(totalDebt, amount);
        // Update debt so interest calculated on remaining debt.
        _decrementDebtOutstanding(amountToPay);
        // Pay to contract as payable of FixedLoanNFT.
        _getWCanto().safeTransferFrom(msg.sender, address(this), amountToPay);
    }

    function withdrawPayable() external returns (uint256) {
        return _withdrawPayable(_getWCanto().balanceOf(address(this)));
    }

    function withdrawPayable(uint256 amount) external returns (uint256) {
        return _withdrawPayable(amount);
    }

    function withdrawNFT() external {
        if (!_isNFTWithdrawable()) {
            revert DebtOutstanding();
        }

        // Cache variables.
        BaseERC721 borrowerNFT = _getBorrowerNFT();
        uint256 csrId = _getCSRId();

        // Verify owner
        if (borrowerNFT.ownerOf(csrId) != msg.sender) {
            revert NotAuthorized();
        }

        // send csrNFT to caller
        _getTurnstile().transferFrom(address(this), msg.sender, csrId);

        // Burn old token.
        borrowerNFT.burn(csrId);

        emit LogCollateralWithdrawn(msg.sender);
    }

    /* -------------------------------- Internal -------------------------------- */

    function _withdrawPayable(uint256 amount) internal returns (uint256) {
        // Cache variables.
        BaseERC721 lenderNFT = _getFixedLoanNFT();
        uint256 csrId = _getCSRId();
        ERC20 wCanto = _getWCanto();

        // Verify owner
        if (lenderNFT.ownerOf(csrId) != msg.sender) {
            revert NotAuthorized();
        }

        wCanto.safeTransfer(msg.sender, amount);

        // Burn lender's NFT once no longer needed.
        if (_isNFTWithdrawable() && wCanto.balanceOf(address(this)) == 0) {
            lenderNFT.burn(csrId);
        }

        emit LogPayableWithdrawn(msg.sender, amount);

        return amount;
    }

    function _isNFTWithdrawable() internal view returns (bool) {
        return debtOutstanding == 0;
    }

    function _decrementDebtOutstanding(uint256 amount) internal {
        debtOutstanding -= amount;
    }

    /**
     * @dev fuzz for rounding of frequent calls.
     */
    function _accrueInterest() internal returns (uint256 totalDebtOutstanding) {
        // Convert to days and multiply by 1 ether for wad math.
        uint256 timePassed = ((block.timestamp + lastAccrual) / 1 days) * 1 ether;
        // currentBid is in 10 bps increments. Div 1k for percent. Multiply by 1 ether for wad math.
        uint256 bps = (uint256(currentBid) * 1 ether) / 1000;
        // Multiply and div by 365.25 ether to convert to days with wad math.
        uint256 rateXTimePassed = (timePassed * bps) / 365.25 ether;
        // See spec.
        uint256 debtMultiplier = uint256(FixedPointMathLib.expWad(int256(rateXTimePassed)));
        // Original debt times multiplier.
        totalDebtOutstanding = FixedPointMathLib.mulWadUp(debtOutstanding, debtMultiplier);

        // Update state.
        debtOutstanding = totalDebtOutstanding;
        lastAccrual = block.timestamp;
    }

    function _getAndUpdateAuctionEnd() internal returns (uint256 auctionEnd) {
        auctionEnd = _getAuctionEnd();
        // Persist overtime end.
        auctionOverTimeEnd = auctionEnd;
    }

    /* ------------------------ Clone With Immutable Args ----------------------- */

    function _getCSROwner() internal pure returns (address) {
        return _getArgAddress(0);
    }

    function _getCSRId() internal pure returns (uint256) {
        return _getArgUint256(20);
    }

    function _getFixedLoanNFT() internal pure returns (BaseERC721) {
        return BaseERC721(_getArgAddress(52));
    }

    function _getBorrowerNFT() internal pure returns (BaseERC721) {
        return BaseERC721(_getArgAddress(72));
    }

    function _getTurnstile() internal pure returns (Turnstile) {
        return Turnstile(_getArgAddress(92));
    }

    function _getWCanto() internal pure returns (ERC20) {
        return ERC20(_getArgAddress(112));
    }

    function _getMaxRate() internal pure returns (uint256) {
        return _getArgUint256(132);
    }

    function _getPrincipalAmount() internal pure returns (uint256) {
        return _getArgUint256(164);
    }

    function _getAuctionEnd() internal returns (uint256) {
        // Save gas until auction goes into overtime.
        uint256 auctionEnd = _getArgUint256(196);

        // When passed the final 15 minutes, sloads are incurred.
        if (block.timestamp >= auctionEnd - 15 minutes) {
            // Check if already in overtime.
            if (auctionOverTimeEnd != 0) {
                // Optimizer removes the double sload.
                auctionEnd = auctionOverTimeEnd;
            }

            // Still within the final 15 minutes
            if (block.timestamp < auctionEnd) {
                // Calculate 15 mins from now.
                auctionEnd = block.timestamp + 15 minutes;
            }
        }

        return auctionEnd;
    }
}
