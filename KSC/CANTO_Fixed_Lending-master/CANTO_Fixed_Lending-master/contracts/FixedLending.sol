// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
// import "https://github.com/paulrberg/prb-math/blob/main/src/UD60x18.sol";
import "@prb/math/src/UD60x18.sol";
import './SVG.sol';
import './Utils.sol';
interface ITurnstile is IERC721{
    function balances(uint256) external view returns (uint256);
    function withdraw(uint256 , address payable , uint256 ) external returns (uint256);
}
contract FixedLendingBond is ERC721{
    uint immutable loanID;
    IERC20 public immutable WCANTO;
    ITurnstile public immutable csrNFT;
    uint public immutable csrNFTId;
    uint public immutable principalAmount;
    uint public immutable maxInterestRate;
    // auction Starter
    address public immutable borrower;

    uint public auctionDeadline;
    uint public currentInterestRate;
    address public lender;
    uint lastAccruedTimestamp;

    bool auctionFinalised;
    bool borrowed;
    uint totalOutstandingDebt;
    uint amountRepaid;
    uint amountWithdrawn;
    bool NFTwithdrawable;

    enum token{lender,borrower} 

    event NewBid(address lender,uint InterestRate);
    event AuctionEnded(address lender,uint InterestRate);
    event LoanRepaid(address borrower,uint amount);
    event NFTWithdrawn(address borrower);

    constructor(uint256 _loanID,address _WCANTO,address _csrNFT,uint _csrNFTId,uint _principalAmount,uint _maxInterestRate,address _borrower) ERC721("FixedLendingBond", "CFLB"){
        loanID = _loanID;
        WCANTO = IERC20(_WCANTO);
        csrNFT = ITurnstile(_csrNFT);
        csrNFTId = _csrNFTId;
        principalAmount = _principalAmount;
        maxInterestRate = _maxInterestRate;
        auctionDeadline = block.timestamp + 24 hours;
        borrower = _borrower;
        currentInterestRate = type(uint).max;
    }

    /**
     * Enables interested lender to bid
     * @param bidRate proposed interest rate
    */
    function bid(uint bidRate) external {
        require(block.timestamp <= auctionDeadline,"bid()# Auction Ended");
        if(block.timestamp >= auctionDeadline - 15 minutes){
            auctionDeadline += 15 minutes;
        }

        require(bidRate <= maxInterestRate,"bid()# bid exceeding maxInterestRate. Bid better");
        require(bidRate < currentInterestRate,"bid()# bid less than currentInterestRate. Bid better");

        // transfer prior bidders principalAmount back to them
        if (currentInterestRate != type(uint).max){
            WCANTO.transfer(lender, principalAmount);
        }
        // transfer principalAmount from bidder to auction object
        require(principalAmount <= WCANTO.allowance(msg.sender, address(this)));
        WCANTO.transferFrom(msg.sender, address(this), principalAmount);

        currentInterestRate = bidRate;
        lender = msg.sender;

        emit NewBid(lender,bidRate);
    }

    /**
     * Enables to finalize after the auctionDeadline
    */
    function finalizeAuction() external {
        require(block.timestamp > auctionDeadline,"finalizeAuction()# Auction still gng. Try 'bid()' ");
        require(!auctionFinalised,"finalizeAuction()# Already Finalized");

        // if no bids, send csrNFT back to auction starter
        if(currentInterestRate == type(uint).max){
            csrNFT.transferFrom(address(this), borrower, csrNFTId);
        }
        else{
            // transfer principalAmount to auction starter
            WCANTO.transfer(borrower, principalAmount);
            totalOutstandingDebt = principalAmount;
            lastAccruedTimestamp = block.timestamp;
            _safeMint(lender, uint(token.lender));
            _safeMint(borrower, uint(token.borrower));
            borrowed = true;
        }
        auctionFinalised = true;
    }

    /**
     * fn to calculated accrued Interest based on time passed from last checkpoint
    */
    function accrueInterest() public view returns (uint){
        // uint timePassed = 3808860;
        uint timePassed = block.timestamp - lastAccruedTimestamp ; 
        uint debtMultiplier = unwrap(exp(ud(timePassed * currentInterestRate * 1 ether / (1000*31557600)))) ; // 31557600 = 365.25 * 24 * 60 * 60
        return debtMultiplier * totalOutstandingDebt / 1 ether;
    }

    /**
     * Enables borrower to repay loan using accumlated CANTO by csr nft ( fees)
    */
    function repayWithClaimable() external {
        require(borrowed,"repayWithClaimable()# Not yet Borrowed");
        require(msg.sender == ownerOf(uint(token.borrower)),"repayWithClaimable()# only borrower can repay");
        uint outstandingDebt = accrueInterest();
        uint claimableAmt = csrNFT.balances(csrNFTId);
        uint withdrawAmt = totalOutstandingDebt <= claimableAmt ? totalOutstandingDebt : claimableAmt ; 
        csrNFT.withdraw(csrNFTId,payable(address(this)),withdrawAmt);
        amountRepaid += withdrawAmt;
        totalOutstandingDebt = outstandingDebt - withdrawAmt;
        lastAccruedTimestamp = block.timestamp;
        if (totalOutstandingDebt == 0 ){
            NFTwithdrawable = true;
        }
    }

    /**
     * Enables borrower to repay loan using  CANTO owned by him ( fees)
    */
    function repayWithExternal(uint amount) external {
        require(borrowed,"repayWithExternal()# Not yet Borrowed");
        require(msg.sender == ownerOf(uint(token.borrower)),"repayWithExternal()# only borrower can repay");
        uint outstandingDebt = accrueInterest();
        uint transferAmt = totalOutstandingDebt <= amount ? totalOutstandingDebt : amount ; 
        
        require(transferAmt <= WCANTO.allowance(msg.sender, address(this)));
        WCANTO.transferFrom(msg.sender, address(this), transferAmt);
        amountRepaid += transferAmt;
        totalOutstandingDebt = outstandingDebt - transferAmt;
        lastAccruedTimestamp = block.timestamp;
        if (totalOutstandingDebt == 0 ){
            NFTwithdrawable = true;
        }
    }

    /**
     * Enables lender to collect `amount` of canto from total interest accrued
    */
    function withdrawPayable(uint amount) public {
        require(msg.sender == ownerOf(uint(token.lender)),"withdrawPayable()# Not a Lender");
        require(amount <= WCANTO.balanceOf(address(this)));
        require(amount <= amountRepaid - amountWithdrawn);
        amountWithdrawn += amount;
        WCANTO.transfer(msg.sender, amount);
    }

    /**
     * Enables lender to withdraw all total interest accrued
    */
    function withdrawPayable() external {
        withdrawPayable(amountRepaid - amountWithdrawn);
    }

    /**
     * Enables borrower to reclaim collateral csr nft after repaying loan
    */
    function withdrawNFT() external {
        require(NFTwithdrawable,"withdrawNFT()# Repay pending debt");
        require(msg.sender == ownerOf(uint(token.borrower)),"withdrawNFT()# Not a Borrower");
        csrNFT.transferFrom(address(this), msg.sender, csrNFTId);
    }

    function tokenURI(uint256 tokenID) public view override returns (string memory){
        if (tokenID == uint(token.lender)){
            return string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="300" style="background:#000">',
                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '40'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(
                        svg.cdata('CANTO-FIXED LENDING BOND #'),
                        utils.uint2str(loanID)
                    )
                ),
                svg.rect(
                    string.concat(
                        svg.prop('fill', 'purple'),
                        svg.prop('x', '20'),
                        svg.prop('y', '50'),
                        svg.prop('width', utils.uint2str(400)),
                        svg.prop('height', utils.uint2str(10))
                    ),
                    utils.NULL
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '100'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Position       : Lender '))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '140'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Address        :  '),toString(ownerOf(uint(token.lender))))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '180'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Amount Lended  :  '),utils.uint2str(principalAmount),svg.cdata(' CANTO'))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '220'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('collateral     :  '),utils.uint2str(csrNFTId),svg.cdata(' CSR NFT'))
                ),
                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '260'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Amount Withdrawn  :  '),utils.uint2str(amountWithdrawn),svg.cdata(' CANTO'))
                ),
                '</svg>'
            );
        } else if (tokenID == uint(token.borrower)){
            return string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500" style="background:#000">',
                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '40'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(
                        svg.cdata('CANTO-FIXED LENDING BOND #'),
                        utils.uint2str(loanID)
                    )
                ),
                svg.rect(
                    string.concat(
                        svg.prop('fill', 'purple'),
                        svg.prop('x', '20'),
                        svg.prop('y', '50'),
                        svg.prop('width', utils.uint2str(400)),
                        svg.prop('height', utils.uint2str(10))
                    ),
                    utils.NULL
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '100'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Position       : Borrower '))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '140'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Address        :  '),toString(ownerOf(uint(token.borrower))))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '180'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Amount Borrowed  :  '),utils.uint2str(principalAmount),svg.cdata(' CANTO'))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '220'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('collateral     :  '),utils.uint2str(csrNFTId),svg.cdata(' CSR NFT'))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '260'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Amount Repaid     :  '),utils.uint2str(amountRepaid),svg.cdata(' CANTO'))
                ),

                svg.text(
                    string.concat(svg.prop('x', '20'),svg.prop('y', '300'),svg.prop('font-size', '22'),svg.prop('fill', 'white')),
                    string.concat(svg.cdata('Total Outstanding Debt     :  '),utils.uint2str(totalOutstandingDebt),svg.cdata(' CANTO'))
                ),

                '</svg>'
            );
        }
    }

    function toString(address account) public pure returns(string memory) {
        return toString(abi.encodePacked(account));
    }

    function toString(uint256 value) public pure returns(string memory) {
        return toString(abi.encodePacked(value));
    }

    function toString(bytes32 value) public pure returns(string memory) {
        return toString(abi.encodePacked(value));
    }

    function toString(bytes memory data) public pure returns(string memory) {
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint i = 0; i < data.length; i++) {
            str[2+i*2] = alphabet[uint(uint8(data[i] >> 4))];
            str[3+i*2] = alphabet[uint(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }
}

