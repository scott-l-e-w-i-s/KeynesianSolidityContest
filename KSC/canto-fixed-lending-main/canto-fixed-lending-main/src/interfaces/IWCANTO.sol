// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IERC20 } from "openzeppelin-contracts/interfaces/IERC20.sol";

interface IWCANTO is IERC20 {
    function deposit() external payable;
}
