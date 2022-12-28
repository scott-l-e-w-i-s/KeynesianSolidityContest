// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.0;

import "solmate/tokens/ERC721.sol";

/// @title Mintable NFT
/// @notice NFT that is mintable by the Factory, used as Fixed Loan NFT and Borrower NFT
contract MintableNFT is ERC721 {
    /*//////////////////////////////////////////////////////////////
                                 ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference to the Factory, used for minting
    address public immutable factory;

    /// @notice Base URI of the NFT
    string public baseURI;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyFactoryCanMint();
    error TokenNotMinted();

    /// @notice Sets the name, symbol, baseURI, and the address of the auction factory
    /// @param _name Name of the NFT
    /// @param _symbol Symbol of the NFT
    /// @param _baseURI NFT base URI. {id}.json is appended to this URI
    /// @param _factory Address of the factory. Only the factory is allowed to mint
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseURI,
        address _factory
    ) ERC721(_name, _symbol) {
        factory = _factory;
        baseURI = _baseURI;
    }

    /// @notice Mint a NFT. Only callable by the factory
    /// @param _to Recipient
    /// @param _id NFT ID, corresponds to the auction and loan ID
    function mint(address _to, uint256 _id) public {
        if (msg.sender != factory) revert OnlyFactoryCanMint();
        _mint(_to, _id); // _safeMint is not used on purpose because the recipient could avoid the finalization of an auction, otherwise
    }

    /// @notice Get the token URI for the provided ID
    /// @param _id ID to retrieve the URI for
    function tokenURI(uint256 _id)
        public
        view
        override
        returns (string memory)
    {
        if (_ownerOf[_id] == address(0))
            // According to ERC721, this revert for non-existing tokens is required
            revert TokenNotMinted();
        return string(abi.encodePacked(baseURI, _id, ".json"));
    }
}
