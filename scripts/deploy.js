const { ethers, run } = require('hardhat');
const { setTimeout } = require("timers/promises");

async function deployNFTContract(artifact, args, uriBase) {
  const Contract = await ethers.getContractFactory(artifact);
  const contract = await Contract.deploy(...args);
  await contract.deployed();
  console.log(`new ${artifact} contract deployed to ${contract.address}`);
  let uri = `${uriBase}${contract.address.toLowerCase()}/`;
  const tx = await contract.updateBaseURI(uri);
  await setTimeout(10000)
  await run("verify:verify", {
    address: contract.address,
    constructorArguments: args,
  });
}

async function deployPeriphery() {
  const wallets = await ethers.getSigners();
  const wallet = wallets[1];
  const donationAddress = wallet.address;
  const Planner = await ethers.getContractFactory('BatchPlanner');
  const planner = await Planner.deploy();
  await planner.deployed();
  console.log(`new planner deployed to ${planner.address}`);
  const Claimer = await ethers.getContractFactory('ClaimCampaigns');
  const claimer = await Claimer.connect(wallet).deploy(donationAddress);
  await claimer.deployed();
  console.log(`new claimer deployed to ${claimer.address}`);
  await setTimeout(10000)
  await run("verify:verify", {
    address: claimer.address,
    constructorArguments: [donationAddress],
  });
  await run("verify:verify", {
    address: planner.address,
  });
}

async function deployAll(artifacts, args, uri, network) {
  const uriBase = `${uri}${network}`;
  for (let i = 0; i < artifacts.length; i++) {
    await deployNFTContract(artifacts[i], args[i], uriBase);
  }
  deployPeriphery();
}

const artifacts = [
  'TokenVestingPlans',
  'VotingTokenVestingPlans',
  'TokenLockupPlans',
  'VotingTokenLockupPlans',
  'TokenLockupPlans_Bound',
  'VotingTokenLockupPlans_Bound',
];
const args = [
  ['TokenVestingPlans', 'TVP'],
  ['VotingTokenVestingPlans', 'VTVP'],
  ['TokenLockupPlans', 'TLP'],
  ['VotingTokenLockupPlans', 'VTLP'],
  ['Bound-TokenLockupPlans', 'B-TLP'],
  ['Bound-VotingTokenLockupPlans', 'B-VTLP'],
];
const uri = 'https://dynamic-nft.hedgey.finance/';
const network = 'mode/'

deployAll(artifacts, args, uri, network);
