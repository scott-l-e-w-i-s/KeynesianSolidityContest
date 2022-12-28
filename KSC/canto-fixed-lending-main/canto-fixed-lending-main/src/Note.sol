// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ERC721 } from "openzeppelin-contracts/token/ERC721/ERC721.sol";

/**
 * @title Loan Note NFT
 * @notice a simple ERC721 token used as an access token
 */
contract Note is ERC721 {
    uint256 public tokenId;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) { }

    /// @dev minting does not give any special permissions, the LoanManager contract assigns permissions itself to token ids
    function mint(address to) public returns (uint256) {
        uint256 nextTokenId = ++tokenId;
        _mint(to, nextTokenId);
        return nextTokenId;
    }
}
