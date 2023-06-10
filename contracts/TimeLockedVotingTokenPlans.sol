// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import './libraries/TransferHelper.sol';
import './libraries/TimelockLibrary.sol';
import './sharedContracts/VotingVault.sol';
import './sharedContracts/URIAdmin.sol';
import './sharedContracts/LockedStorage.sol';

import 'hardhat/console.sol';

contract TimeLockedVotingTokenPlans is ERC721Enumerable, LockedStorage, ReentrancyGuard, URIAdmin {
  using Counters for Counters.Counter;
  Counters.Counter private _planIds;

  mapping(uint256 => address) internal votingVaults;

  event VotingVaultCreated(uint256 indexed id, address vaultAddress);

  constructor(string memory name, string memory symbol) ERC721(name, symbol) {
    uriAdmin = msg.sender;
  }

  function _baseURI() internal view override returns (string memory) {
    return baseURI;
  }

  /****CORE EXTERNAL FUNCTIONS*********************************************************************************************************************************************/

  function createPlan(
    address recipient,
    address token,
    uint256 amount,
    uint256 start,
    uint256 cliff,
    uint256 rate,
    uint256 period
  ) external nonReentrant {
    require(recipient != address(0), '01');
    require(token != address(0), '02');
    require(amount > 0, '03');
    require(rate > 0, '04');
    require(rate <= amount, '05');
    _planIds.increment();
    uint256 newPlanId = _planIds.current();
    uint256 end = TimelockLibrary.endDate(start, amount, rate, period);
    require(cliff <= end, 'SV12');
    TransferHelper.transferTokens(token, msg.sender, address(this), amount);
    plans[newPlanId] = Plan(token, amount, start, cliff, rate, period);
    _safeMint(recipient, newPlanId);
    emit PlanCreated(newPlanId, recipient, token, amount, start, cliff, end, rate, period);
  }

  function redeemPlans(uint256[] memory planIds) external nonReentrant {
    _redeemPlans(planIds, block.timestamp);
  }

  function partialRedeemPlans(uint256[] memory planIds, uint256 redemptionTime) external nonReentrant {
    require(redemptionTime < block.timestamp, '!future redemption');
    _redeemPlans(planIds, redemptionTime);
  }

  function redeemAllPlans() external nonReentrant {
    uint256 balance = balanceOf(msg.sender);
    uint256[] memory planIds = new uint256[](balance);
    for (uint256 i; i < balance; i++) {
      uint256 planId = tokenOfOwnerByIndex(msg.sender, i);
      planIds[i] = planId;
    }
    _redeemPlans(planIds, block.timestamp);
  }

  function segmentPlans(uint256 planId, uint256[] memory segmentAmounts) external nonReentrant {
    for (uint256 i; i < segmentAmounts.length; i++) {
      _segmentPlan(msg.sender, planId, segmentAmounts[i]);
    }
  }

  function segmentAndDelegatePlans(uint256 planId, uint256[] memory segmentAmounts, address[] memory delegatees) external nonReentrant {
    for (uint256 i; i < segmentAmounts.length; i++) {
      uint256 newPlanId =  _segmentPlan(msg.sender, planId, segmentAmounts[i]);
      _delegate(msg.sender, newPlanId, delegatees[i]);
    }
  }

  function combinePlans(uint256 planId0, uint256 planId1) external nonReentrant {
    _combinePlans(msg.sender, planId0, planId1);
  }

  /****CORE INTERNAL FUNCTIONS*********************************************************************************************************************************************/

  function _redeemPlans(uint256[] memory planIds, uint256 redemptionTime) internal {
    for (uint256 i; i < planIds.length; i++) {
      (uint256 balance, uint256 remainder, uint256 latestUnlock) = planBalanceOf(
        planIds[i],
        block.timestamp,
        redemptionTime
      );
      if (balance > 0) _redeemPlan(msg.sender, planIds[i], balance, remainder, latestUnlock);
    }
  }

  function _redeemPlan(
    address holder,
    uint256 planId,
    uint256 balance,
    uint256 remainder,
    uint256 latestUnlock
  ) internal {
    require(ownerOf(planId) == holder, '!holder');
    Plan memory plan = plans[planId];
    address vault = votingVaults[planId];
    if (balance == plan.amount) {
      delete plans[planId];
      delete votingVaults[planId];
      _burn(planId);
    } else {
      plans[planId].amount = remainder;
      plans[planId].start = latestUnlock;
    }
    if (vault == address(0)) {
      TransferHelper.withdrawTokens(plan.token, holder, balance);
    } else {
      VotingVault(vault).withdrawTokens(holder, balance);
    }
    emit PlanTokensUnlocked(planId, balance, remainder, latestUnlock);
  }

  function _segmentPlan(address holder, uint256 planId, uint256 segmentAmount) internal returns (uint256 newPlanId) {
    require(ownerOf(planId) == holder, '!holder');
    Plan memory plan = plans[planId];
    require(segmentAmount < plan.amount, 'amount error');
    uint256 end = TimelockLibrary.endDate(plan.start, plan.amount, plan.rate, plan.period);
    _planIds.increment();
    newPlanId = _planIds.current();
    uint256 planAmount = plan.amount - segmentAmount;
    console.log('plan amount is set to:', planAmount);
    plans[planId].amount = planAmount;
    uint256 planRate = (plan.rate * ((planAmount * (10 ** 18)) / plan.amount)) / (10 ** 18);
    console.log('original plan rate is: ', plan.rate);
    console.log('planRate is now set to:', planRate);
    plans[planId].rate = planRate;
    uint256 segmentRate = plan.rate - planRate;
    console.log('segment rate is set to:', segmentRate);
    uint256 planEnd = TimelockLibrary.endDate(plan.start, planAmount, planRate, plan.period);
    uint256 segmentEnd = TimelockLibrary.endDate(plan.start, segmentAmount, segmentRate, plan.period);
    require(planEnd == segmentEnd, '!planEnd');
    require(planEnd >= end, 'plan end error');
    // require(segmentEnd >= end, 'segmentEnd error');
    plans[newPlanId] = Plan(plan.token, segmentAmount, plan.start, plan.cliff, segmentRate, plan.period);
    if (segmentOriginalEnd[planId] == 0) {
      segmentOriginalEnd[planId] = end;
      segmentOriginalEnd[newPlanId] = end;
    } else {
      // dont change the planId original end date, but set this segment to the plans original end date
      segmentOriginalEnd[newPlanId] = segmentOriginalEnd[planId];
    }
    //emit PlanSegmented()
    // now we have to do the onchain stuff if there is a voting vault
    if(votingVaults[planId] != address(0)) {
      // pull tokens back to contract here
      VotingVault(votingVaults[planId]).withdrawTokens(address(this), segmentAmount);
      // setup a new voting vault
      _setupVoting(holder, newPlanId);
    }
  }

  function _combinePlans(address holder, uint256 planId0, uint256 planId1) internal {
    require(ownerOf(planId0) == holder, '!holder');
    require(ownerOf(planId1) == holder, '!holder');
    Plan memory plan0 = plans[planId0];
    Plan memory plan1 = plans[planId1];
    require(plan0.token == plan1.token, 'token error');
    require(plan0.start == plan1.start, 'start error');
    require(plan0.cliff == plan1.cliff, 'cliff error');
    require(plan0.period == plan1.period, 'period error');
    uint256 plan0End = TimelockLibrary.endDate(plan0.start, plan0.amount, plan0.rate, plan0.period);
    uint256 plan1End = TimelockLibrary.endDate(plan1.start, plan1.amount, plan1.rate, plan1.period);
    // either they have the same end date, or if they dont then they should have the same original end date if they were segmented
    require(plan0End == plan1End || segmentOriginalEnd[planId0] == segmentOriginalEnd[planId1], 'end error');
    // add em together and delete plan 1
    plans[planId0].amount += plans[planId1].amount;
    plans[planId0].rate += plans[planId1].rate;
    // have to process the voting vault aspect
    address vault0 = votingVaults[planId0];
    address vault1 = votingVaults[planId1];
    if (vault0 != address(0)) {
      // set this as primary voting vault, check if vault1 has anything
      if (vault1 != address(0)) {
        // transfer funds from vault1 to vault0
        VotingVault(vault1).withdrawTokens(vault0, plan1.amount);
      } else {
        // send funds from here to vault 0
        TransferHelper.withdrawTokens(plan0.token, vault0, plan1.amount);
      }
      delete plans[planId1];
      _burn(planId1);
    } else if (vault1 != address(0)) {
      // we know that vault 0 is empty, so just need to send tokens to vault 1 then
      TransferHelper.withdrawTokens(plan0.token, vault1, plan0.amount);
      // now we keep plan1 instead
      delete plans[planId0];
    _burn(planId0);
    } else {
     delete plans[planId1];
    _burn(planId1);
    }
    
    //emit PlansCombined
  }

  /****VOTING FUNCTIONS*********************************************************************************************************************************************/

  function setupVoting(uint256 planId) external nonReentrant {
    _setupVoting(msg.sender, planId);
  }

  

  function delegate(uint256 planId, address delegatee) external nonReentrant {
    _delegate(msg.sender, planId, delegatee);
  }

  function _setupVoting(address holder, uint256 planId) internal returns (address) {
    require(ownerOf(planId) == holder);
    Plan memory plan = plans[planId];
    VotingVault vault = new VotingVault(plan.token, holder);
    votingVaults[planId] = address(vault);
    TransferHelper.withdrawTokens(plan.token, address(vault), plan.amount);
    emit VotingVaultCreated(planId, address(vault));
    return address(vault);
  }

  function _delegate(address holder, uint256 planId, address delegatee) internal {
    require(ownerOf(planId) == holder);
    address vault = votingVaults[planId];
    require(votingVaults[planId] != address(0), 'no vault setup');
    VotingVault(vault).delegateTokens(delegatee);
  }

  function lockedBalances(address holder, address token) external view returns (uint256 lockedBalance) {
    uint256 holdersBalance = balanceOf(holder);
    for (uint256 i; i < holdersBalance; i++) {
      uint256 planId = tokenOfOwnerByIndex(holder, i);
      Plan memory plan = plans[planId];
      if (token == plan.token) {
        lockedBalance += plan.amount;
      }
    }
  }
}
