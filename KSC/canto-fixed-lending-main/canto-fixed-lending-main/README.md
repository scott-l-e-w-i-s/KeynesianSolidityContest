# ENTRY #4 - Canto Fixed Lending Protocol

Canto Fixed Lending enables lending wrapped Canto tokens (WCANTO) using [CSR](https://github.com/Canto-Improvement-Proposals/CIPs/blob/main/CIP-001.md) NFTs as collateral and repayment.

## Overview

Every new loan starts with the borrower transfering their CSR NFT to the `LoanAuctionHouse`, and kicking off a 24-hour auction auction where lenders can compete by offering a more attractive annual interest rate. A loan is created if there was a bid with a better rate than the limit borrower set.

A loan is created by `LoanAuctionHouse`, transfering the loan principal to the borrower, transfering the CSR NFT to the `LoanManager` contract, and calling the `createLoan` function.

Borrower is able to withdraw their CSR NFT only once the loan is repaid in full; they can repay via their CSR balance, or via external transfers. Lender can withdraw repayments at any time.

All transactions use the WCANTO token.

## Install and test

```bash
forge install
forge test
```

## Deployment

All contracts are deployed by deploying `LoanAuctionHouse`, which takes 2 constructor parameters:

1. `ITurnstile turnstile`: the CSR [Turnstile contract](https://github.com/code-423n4/2022-11-canto/blob/main/CIP-001/src/Turnstile.sol), which manages CSR balances.
2. `IWCANTO wCanto`: the WCANTO token contract.
