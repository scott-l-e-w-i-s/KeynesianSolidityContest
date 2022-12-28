from brownie import *
from dotmap import DotMap
import pytest

def main():
  quick_demo()

def quick_demo():

  ## Setup
  gov = a[1]
  user = a[2]
  bidder = a[3]
  turnstile = Turnstile.deploy({"from": gov})
  keynes = Keynes.deploy(turnstile, {"from": gov})
  fixed_nft = MintableNFT.at(keynes.FIXED_LOAN_NFT())
  borrower_nft = MintableNFT.at(keynes.BORROWER_NFT())

  x = turnstile.register(a[2], {"from": user})
  token_id_to_loan = turnstile.getTokenId(user)
  amount = 1e18
  turnstile.distributeFees(token_id_to_loan, {"value": amount * 10, "from": gov})
  print("Sent Fees to Turnstile")

  assert turnstile.balances(token_id_to_loan) > 0

  bidder_initial_b = bidder.balance()
  print("bidder_initial_b", bidder_initial_b)

  ## Create Auction
  turnstile.approve(keynes, token_id_to_loan, {"from": user})
  auction_tx = keynes.startAuction(amount, 1000, token_id_to_loan, {"from": user})
  auction_id = auction_tx.return_value
  print("Created Auction Id", auction_id)

  keynes.bid(auction_id, 999, {"from": bidder, "value": amount})
  print("Bidding on Auction Id", auction_id)

  chain.sleep(24 * 60 * 60)
  keynes.finalizeAuction(auction_id, {"from": a[0]})
  print("Finalized Auction Id", auction_id)


  print("Check Borrower and Lender NFTs")
  assert borrower_nft.balanceOf(user) == 1
  assert fixed_nft.balanceOf(bidder) == 1

  print("Initial Loan Data", keynes.loans(1))
  print("Repay With climable")
  keynes.repayWithClaimable(1, {"from": a[5]})
  ## Check we have no more debt
  print("Updated Loan Data", keynes.loans(1))

  chain.sleep(2000)
  ## And payable doesn't grow
  keynes.repayWithClaimable(1, {"from": a[5]})
  keynes.loans(1)
  print("Doesn't change after all debt is repaid", keynes.loans(1))


  ## Check withdraw increases balance
  print("Lender Withdraws")
  keynes.withdrawPayable(1, 0, {"from": bidder})
  print("New Lender Balance", bidder.balance())


  turnstile.balanceOf(user)
  ## Withdraw and check it has increased
  keynes.withdrawNFT(1, {"from": user})
  turnstile.balanceOf(user)
  print("Borrower withdraws", bidder.balance())
  print("New Turnstile Borrower Balance", turnstile.balanceOf(user))


  assert bidder.balance() > bidder_initial_b