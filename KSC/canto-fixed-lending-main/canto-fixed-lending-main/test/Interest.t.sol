// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { Interest } from "../src/Interest.sol";

contract InterestTest is Test {
    function testCalcDebt() public {
        uint256 principal = 100000;
        uint16 annualInterestRate = 100; // 10%

        uint256 startTime = 1609507320; // 1/1/2021 13:22
        uint256 currentTime = 1672579320; // 1/1/2023 13:22
        uint256 period = currentTime - startTime;
        assertEq(Interest.calculateCompoundInterest(principal, annualInterestRate, period), 122123);
    }
}
