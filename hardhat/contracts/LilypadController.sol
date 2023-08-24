// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "hardhat/console.sol";
import "./SharedStructs.sol";
import "./ILilypadStorage.sol";

contract LilypadController is Ownable, Initializable {

  /**
   * Types
   */
  address public storageAddress;
  address public tokenAddress;

  ILilypadStorage private storageContract;
  IERC20 private tokenContract;

  /**
   * Events
   */

  event ResourceProviderAgreed(uint256 indexed dealId);
  event JobCreatorAgreed(uint256 indexed dealId);
  event DealAgreed(uint256 indexed dealId);
  event Timeout(uint256 indexed dealId);
  event ResultAdded(uint256 indexed dealId);
  event ResultAccepted(uint256 indexed dealId);
  event ResultRejected(uint256 indexed dealId);

  /**
   * Init
   */

  // https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
  function initialize(address _storageAddress, address _tokenAddress) public initializer {
    setStorageAddress(_storageAddress);
    setTokenAddress(_tokenAddress);
  }

  function setStorageAddress(address _storageAddress) public onlyOwner {
    require(_storageAddress != address(0), "Storage address must be defined");
    storageAddress = _storageAddress;
    storageContract = ILilypadStorage(storageAddress);
  }

  function setTokenAddress(address _tokenAddress) public onlyOwner {
    require(_tokenAddress != address(0), "Token address must be defined");
    tokenAddress = _tokenAddress;
    tokenContract = IERC20(storageAddress);
  }

  /**
   * Agreements
   */

  function agree(
    uint256 dealId,
    address resourceProvider,
    address jobCreator,
    uint256 instructionPrice,
    uint256 timeout,
    uint256 timeoutCollateral,
    uint256 jobCollateral,
    uint256 resultsCollateral
  ) public returns (SharedStructs.Agreement memory) {
    require(storageContract.isNegotiating(dealId), "Deal is not in negotiation state");
    require(resourceProvider != address(0), "RP must be defined");
    require(jobCreator != address(0), "JC must be defined");
    require(resourceProvider != jobCreator, "RP and JC cannot be the same");

    // we already have this deal and so the values must line up
    if(storageContract.hasDeal(dealId)) {
      SharedStructs.Deal memory existingDeal = storageContract.getDeal(dealId);
      require(existingDeal.resourceProvider == resourceProvider, "RP does not match");
      require(existingDeal.jobCreator == jobCreator, "JC does not match");
      require(existingDeal.instructionPrice == instructionPrice, "Instruction price does not match");
      require(existingDeal.timeout == timeout, "Timeout does not match");
      require(existingDeal.timeoutCollateral == timeoutCollateral, "Timeout collateral does not match");
      require(existingDeal.jobCollateral == jobCollateral, "Job collateral does not match");
      require(existingDeal.resultsCollateral == resultsCollateral, "Results collateral does not match");
    }
    else {
      // we don't have this deal yet so add it
      storageContract.addDeal(
        dealId,
        resourceProvider,
        jobCreator,
        instructionPrice,
        timeout,
        timeoutCollateral,
        jobCollateral,
        resultsCollateral
      );
    }

    SharedStructs.Deal memory deal = storageContract.getDeal(dealId);
    bool isResourceProvider = tx.origin == deal.resourceProvider;
    bool isJobCreator = tx.origin == deal.jobCreator;
    require(isResourceProvider || isJobCreator, "Only RP or JC can agree to deal");

    if(isResourceProvider) {
      storageContract.agreeResourceProvider(dealId);
      _payIn(deal.timeoutCollateral);
      emit ResourceProviderAgreed(dealId);
    }
    else if(isJobCreator) {
      storageContract.agreeJobCreator(dealId);
      _payIn(deal.jobCollateral);
      emit JobCreatorAgreed(dealId);
    }

    // both sides have agreed!
    if(storageContract.isAgreement(dealId)) {
      emit DealAgreed(dealId);
    }

    return storageContract.getAgreement(dealId);
  }

  /**
   * Results
   */

  // * check the RP is calling this
  // * mark the deal as results submitted
  // * work out the difference between the timeout and results collateral
  // * pay the difference into / out of the contract
  // * emit the event
  function addResult(
    uint256 dealId,
    uint256 resultsId,
    uint256 instructionCount
  ) public returns (SharedStructs.Result memory) {
    require(storageContract.isAgreement(dealId), "Deal is not in agreement state");
    require(!_hasTimedOut(dealId), "Deal has timed out");
    SharedStructs.Deal memory deal = storageContract.getDeal(dealId);
    require(deal.resourceProvider == tx.origin, "Only RP can add results");

    SharedStructs.Result memory newResult = storageContract.addResult(
      dealId,
      resultsId,
      instructionCount
    );

    // this is how much we need to pay out to the RP or be paid by the RP
    // a positive number means we are owed money
    // a negative number means we pay the RP a refund
    int256 rpCollateralDiff = int256(deal.resultsCollateral) - int256(deal.timeoutCollateral);

    if(rpCollateralDiff > 0) {
      // the RP pays us because the job collateral is higher than the timeout collateral
      _payIn(uint256(rpCollateralDiff));
    }
    else if(rpCollateralDiff < 0) {
      // we pay the RP because the job collateral is lower
      _payOut(deal.resourceProvider, uint256(rpCollateralDiff));
    }

    emit ResultAdded(dealId);

    return newResult;
  }

  // the job creator calls this after the timeout has passed
  // and there are no results submitted
  function acceptResults(
    uint256 dealId
  ) public {

  }

  function rejectResults(
    uint256 dealId
  ) public {

  }

  // the job creator calls this after the timeout has passed and there are no results submitted
  // https://ethereum.stackexchange.com/questions/86633/time-dependent-tests-with-hardhat
  // * check the JC is calling this
  // * mark the deal as timedout
  // * pay back the JC's job collateral
  // * emit the event
  function refundTimeout(
    uint256 dealId
  ) public {
    require(storageContract.isAgreement(dealId), "Deal is not in agreement state");
    require(_hasTimedOut(dealId), "Deal has not timed out yet");
    SharedStructs.Deal memory deal = storageContract.getDeal(dealId);
    require(deal.jobCreator == tx.origin, "Only JC can refund timeout");
    storageContract.timeoutResult(dealId);

    _payOut(deal.jobCreator, deal.jobCollateral);

    emit Timeout(dealId);
  }

  function _hasTimedOut(
    uint256 dealId
  ) private returns (bool) {
    SharedStructs.Deal memory deal = storageContract.getDeal(dealId);
    SharedStructs.Agreement memory agreement = storageContract.getAgreement(dealId);
    return block.timestamp > agreement.dealAgreedAt + deal.timeout;
  }

  /**
   * Payments
   */

  

  // move tokens around inside the erc-20 contract
  function _pay(
    address from,
    address to,
    uint256 amount
  ) private {
    require(tokenContract.balanceOf(from) >= amount, "Insufficient balance");
    require(tokenContract.allowance(from, to) >= amount, "Allowance too low");
    bool success = tokenContract.transferFrom(from, to, amount);
    require(success, "Transfer failed");
  }

  // take X tokens from the tx sender and add them to the contract's token balance
  function _payIn(
    uint256 amount
  ) private {
    // approve the tokens we are about to move
    // this works because _payIn is always called as part of the user who is paying
    // into the contract
    tokenContract.approve(address(this), amount);
    _pay(
      tx.origin,
      address(this),
      amount
    );
  }

  // take X tokens from the contract's token balance and send them to the given address
  function _payOut(
    address payWho,
    uint256 amount
  ) private {
    _pay(
      address(this),
      payWho,
      amount
    );
  }
}





