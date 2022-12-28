// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { ERC721 } from "solmate/tokens/ERC721.sol";
import { Owned } from "solmate/auth/Owned.sol";

contract BaseERC721 is ERC721, Owned(msg.sender) {
    error NotAuthorized();

    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /* ---------------------------------- Owner --------------------------------- */

    /**
     * @notice Ownership is used for the purpose of minting and is not intended to ever be transferred.
     */
    function mint(address to, uint256 tokenId) public virtual onlyOwner {
        _mint(to, tokenId);
    }

    /* ---------------------------- Public Overrides ---------------------------- */

    function burn(uint256 tokenId) public virtual {
        address tokenOwner = _ownerOf[tokenId];
        if (msg.sender != tokenOwner && !isApprovedForAll[tokenOwner][msg.sender]) {
            revert NotAuthorized();
        }

        _burn(tokenId);
    }

    function tokenURI(uint256 /* id */) public view virtual override returns (string memory) {
        return "";
    }
}
