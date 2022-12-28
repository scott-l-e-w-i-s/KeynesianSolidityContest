// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IERC721Enumerable } from "openzeppelin-contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface ITurnstile is IERC721Enumerable {
    /// @notice maps tokenId to fees earned
    function balances(uint256 tokenId) external view returns (uint256);

    /// @notice Withdraws earned fees to `_recipient` address. Only callable by NFT owner.
    /// @param _tokenId token Id
    /// @param _recipient recipient of fees
    /// @param _amount amount of fees to withdraw
    /// @return amount of fees withdrawn
    function withdraw(uint256 _tokenId, address payable _recipient, uint256 _amount) external returns (uint256);
}
