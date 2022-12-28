// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./FixedLending.sol";

contract CantoFixedLending{
    
    address[] public loans;

    address public immutable WCANTO;
    IERC721 public immutable csrNFT;

    constructor(address _WCANTO,address _csrNFT){
        WCANTO = _WCANTO;
        csrNFT = IERC721(_csrNFT);
    }


    /**
     * Enables an csrNFT owner to take a loan, specifying parameters
     * @param csrNFTId NFT token id
     * @param principalAmount total amount to borrow
     * @param maxInterestRate allowed interest rate precentage (10 basis points)
     * @return Loan id , loan contract address
    */
    function startAuction(uint csrNFTId,uint principalAmount,uint maxInterestRate) external returns (uint,address){
        require(csrNFT.ownerOf(csrNFTId) == msg.sender,"startAuction()# Not a owner");
        require(csrNFT.isApprovedForAll(msg.sender, address(this)) || csrNFT.getApproved(csrNFTId) == address(this),"startAuction()# Need approval for csrNFT");
        uint loanID = loans.length;
        FixedLendingBond bond = new FixedLendingBond(loanID,WCANTO,address(csrNFT),csrNFTId,principalAmount,maxInterestRate,msg.sender);

        csrNFT.transferFrom(msg.sender, address(bond), csrNFTId);
        loans.push(address(bond));
        return (loanID,address(bond));
    }

}