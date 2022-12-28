// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCast } from "openzeppelin-contracts/utils/math/SafeCast.sol";

/**
 * @dev Compound interest calculator.
 */
library Interest {
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 public constant YEAR = 365.25 days;

    /**
     * @notice Calculates continuous compounding interest
     * @dev uses the formula: P * e^(R*T) where R is the annual interest rate and T is the number of years
     * @param principalAmount the principal amount
     * @param rate Annual interest rate in units of 10 bps, i.e 15 = 1.5%
     * @param period number of seconds to calculate the interest over
     * @return uint256 principal amount with the compounded interest
     */
    function calculateCompoundInterest(uint256 principalAmount, uint16 rate, uint256 period)
        public
        pure
        returns (uint256)
    {
        uint256 exponent = (rate * period * 1e18 / YEAR) / 1000;
        int256 debtMultiplier = FixedPointMathLib.expWad(exponent.toInt256());
        return FixedPointMathLib.mulDiv(principalAmount, debtMultiplier.toUint256(), 1e18);
    }
}
