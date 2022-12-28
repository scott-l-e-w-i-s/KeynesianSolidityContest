// SPDX-License-Identifier: GPL-3
pragma solidity 0.8.17;


interface ITurnstile {
  function balances(uint256 tokenId) external view returns (uint256);

  function withdraw(uint256 _tokenId, address payable _recipient, uint256 _amount) external returns (uint256);

  function distributeFees(uint256 _tokenId) external payable;

  function register(address _recipient) external returns (uint256 tokenId);
  function assign(uint256 _tokenId) external returns (uint256);

  function safeTransferFrom(
    address from,
    address to,
    uint256 tokenId
  ) external;
}