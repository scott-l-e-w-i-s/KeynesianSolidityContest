// SPDX-License-Identifier: GPL-3
pragma solidity 0.8.17;

import {ERC721} from "@oz/token/ERC721/ERC721.sol";

/// @dev Simple NFT Contract, mintable exclusively by the deployer
contract MintableNFT is ERC721 {
    address immutable minter;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) {
        minter = msg.sender;
    }

    /// @dev Mint for a specific ID
    /// @notice Keynes will only mint one per tokenId
    ///   The TokenId represents a Loan
    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}
