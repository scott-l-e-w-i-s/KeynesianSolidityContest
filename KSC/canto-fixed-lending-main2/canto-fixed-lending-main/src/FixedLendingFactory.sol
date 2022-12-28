// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { BaseERC721 } from "src/BaseERC721.sol";
import { FixedLending } from "src/FixedLending.sol";
import { IFixedLendingFactory } from "src/IFixedLendingFactory.sol";
import { Turnstile } from "src/vendor/Turnstile.sol";
import { ClonesWithImmutableArgs } from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

contract FixedLendingFactory is IFixedLendingFactory {
    /* ---------------------------- Public Constants ---------------------------- */

    uint256 public constant BPS_CAP = 250; // 25% max interest rate in 10 bps increments.
    BaseERC721 public immutable fixedLoanNFT;
    BaseERC721 public immutable borrowerNFT;
    FixedLending public immutable fixedLending;
    Turnstile public immutable turnstile;
    address public immutable wCanto;

    /* ------------------------------- Constructor ------------------------------ */

    /**
     * @param _turnstile address of CSR Turnstile contract.
     * @param _csrFLSalt create2 salt for safe vanity address control on the CSR Fixed Loan Contract.
     * @param _csrBWSalt create2 salt for safe vanity address control on the CSR Borrower Contract.
     */
    constructor(Turnstile _turnstile, address _wCanto, bytes32 _csrFLSalt, bytes32 _csrBWSalt) {
        // Validate user input, cannot be address 0 and must be contract.
        if (address(_turnstile) == address(0) || address(_turnstile).code.length == 0) {
            revert InvalidAddress();
        }
        if (_wCanto == address(0) || _wCanto.code.length == 0) {
            revert InvalidAddress();
        }

        // Deploy as owner and persist.
        fixedLoanNFT = new BaseERC721{ salt: _csrFLSalt }("CSR Fixed Loan", "csrFL");
        borrowerNFT = new BaseERC721{ salt: _csrBWSalt }("CSR Borrower", "csrBW");

        // Deploy implementation.
        fixedLending = new FixedLending();

        // Persist.
        turnstile = _turnstile;
        wCanto = _wCanto;
    }

    /* ---------------------------- Public Functions ---------------------------- */

    function startAuction(
        uint256 principalAmount,
        uint256 maxRate,
        uint256 csrNFTId
    ) external override returns (address) {
        // maxRate must be below BPS_CAP.
        if (maxRate > BPS_CAP) {
            revert InvalidMaxRate();
        }
        // csrNFTId must exist.
        address csrNFTOwner = turnstile.ownerOf(csrNFTId);
        // Must be called by owner OR approved by owner.
        if (csrNFTOwner != msg.sender && !turnstile.isApprovedForAll(csrNFTOwner, msg.sender)) {
            revert NotAuthorized();
        }

        // Deploy
        bytes memory data = abi.encodePacked(
            csrNFTOwner,
            csrNFTId,
            address(fixedLoanNFT),
            address(borrowerNFT),
            address(turnstile),
            wCanto,
            maxRate,
            principalAmount,
            block.timestamp + 1 days
        );
        address fixedLendingClone = ClonesWithImmutableArgs.clone(address(fixedLending), data);

        // Mint NFTs to FixedLending contract for handling.
        fixedLoanNFT.mint(fixedLendingClone, csrNFTId);
        borrowerNFT.mint(fixedLendingClone, csrNFTId);

        // Transfer collateral to fixedLendingClone.
        turnstile.transferFrom(csrNFTOwner, fixedLendingClone, csrNFTId);

        emit LogAuctionCreated(fixedLendingClone, csrNFTId, principalAmount, maxRate);

        return fixedLendingClone;
    }
}
