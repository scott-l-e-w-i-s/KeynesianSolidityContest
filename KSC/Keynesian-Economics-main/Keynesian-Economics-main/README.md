# ENTRY #3 - Keynes - Get paid today for your CSR

## Demo

The demo sets up a few contracts and then

Run the demo via 

```bash 
brownie run demo
```

See demo output below



## Architecture Notes:
https://miro.com/app/board/uXjVP7f4bjM=/?share_link_id=455737749175

The Architecture chosen follows the spec given, but to save gas, instead of deploying multiple contracts, the logic is handled by one contract.

The storage mappings effectively act as the different objects, as shown in the Miro Above.

The one consistent change throughout this architecture is that each function (beside startAuction), will have the ID of the Auction / Loan as it's first parameter.

## Matching IDs to KIS
Auction and Loans could have desynched or even gibberish IDs, but for the sake of convenience I've made it so that:
- Auctions have sequential IDs (++)
- Loans that spawn from successful auctions retain the same ID

This offers some clever skips and also should help code the frontend as well as make it easier to interact via a block explorer.

## Immutables and Caching
Whenever possible, I've used immutable values, as this contract is intended to be without governance.

I had the contract also deploy 2 NFT contracts on first deploy, allowing this relation to be immutable on both ways (saving gas and avoiding need for permissioned setup)

I also cached values read from storage (those variables are called `cachedXYZ`, e.g. `cachedAuctionId`), to save gas

## Gas Benchmark for Exponentiation

## Quad vs 64

64/64 is cheaper and has no loss of precision for our use case
### QUAD
history[-1].gas_used
33812


### 64
res.gas_used
26830

## Demo Output
```python
Running 'scripts/demo.py::main'...
Transaction sent: 0x9f97066dfaf1807466e97a6cf500bd88fd2c8140a1965f765a16b923278e8d3b
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 5
  Turnstile.constructor confirmed   Block: 16162235   Gas used: 1970102 (16.42%)
  Turnstile deployed at: 0x8F37Fb31d618513553fdF93e90c4C11BD8bf112c

Transaction sent: 0xc93376d5d7e0f42466e7b3aab08a2859170963812afea51794f40498aa0e61d1
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 6
  Keynes.constructor confirmed   Block: 16162236   Gas used: 4350046 (36.25%)
  Keynes deployed at: 0x3EbF54363552bbCeEFacA481BebD832E978482F3

Transaction sent: 0x75a5ef02bbee0dd54343994dd710cc5b91ea076613a8dca78002e04f3b3d14f2
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 0
  Turnstile.register confirmed   Block: 16162237   Gas used: 185061 (1.54%)

Transaction sent: 0x985d7e8541b1ff9c80f94fbe5010df596c28a768defa4754626865ee312210a9
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 7
  Turnstile.distributeFees confirmed   Block: 16162238   Gas used: 44652 (0.37%)

Sent Fees to Turnstile
bidder_initial_b 100000000000000000000
Transaction sent: 0x4e6ff4672631d0d89123c6547341add23be6b8bdfc2799db2ae764ab51194019
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 1
  Turnstile.approve confirmed   Block: 16162239   Gas used: 46836 (0.39%)

Transaction sent: 0x5bb099d4f5c0cc8c1a4d016693fc4d698a9b4b4ab4e0420fbbf2d8bba17e9fd0
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 2
  Keynes.startAuction confirmed   Block: 16162240   Gas used: 183256 (1.53%)

Created Auction Id 1
Transaction sent: 0x92e896024cf0cec291c664072c939bf9e4352b6ce47d697f355ff030054cfe8a
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 0
  Keynes.bid confirmed   Block: 16162241   Gas used: 36042 (0.30%)

Bidding on Auction Id 1
Transaction sent: 0xcb34519398f032af4f5993091a5ddce25e01327d47af69d11132e55920239bb1
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 6
  Keynes.finalizeAuction confirmed   Block: 16162242   Gas used: 218954 (1.82%)

Finalized Auction Id 1
Check Borrower and Lender NFTs
Initial Loan Data (1000000000000000000, 1670857339, 999, 0, 1, False)
Repay With climable
Transaction sent: 0x5385520162ee7a8c538aaf4218d9bb2aa80b9ec783b332b334b19d67c9ca46b9
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 0
  Keynes.repayWithClaimable confirmed   Block: 16162243   Gas used: 55737 (0.46%)

Updated Loan Data (0, 1670857341, 999, 1000000006331279965, 1, False)
Transaction sent: 0x2dbf472fad6b6cdb7bf42e6f21ade4280341fa1ec36fa753f9ab4a44d531efa0
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 1
  Keynes.repayWithClaimable confirmed   Block: 16162244   Gas used: 31487 (0.26%)

"Doesn't change after all debt is repaid (0, 1670857341, 999, 1000000006331279965, 1, False)"
Lender Withdraws
Transaction sent: 0x4364be871ddb97c12ebd4271c264ea8166e8b4820ff2e0885368b8a3d63eb8db
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 1
  Keynes.withdrawPayable confirmed   Block: 16162245   Gas used: 22463 (0.19%)

New Lender Balance 100000000006331279965
Transaction sent: 0xed33a6f797437edc6b3684a034418daa562dbb4e5ba51989524c167c9ebf9c11
  Gas price: 0.0 gwei   Gas limit: 12000000   Nonce: 3
  Keynes.withdrawNFT confirmed   Block: 16162246   Gas used: 45293 (0.38%)

Borrower withdraws 100000000006331279965
New Turnstile Borrower Balance 1
```

## What's next

Packing of variables

Full coverage

Perhaps refactoring into separate files, but with the current size of the project I think the a simple file structure is fine
