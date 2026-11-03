const prompt = require('prompt');
const hre = require("hardhat");
const { type2Transaction } = require('./utils.js');

async function main() {
  console.log("Upgradable strategy deployment.");
  console.log("Specify a the vault address, and the strategy implementation's name");
  prompt.start();
  const addresses = require("../test/test-config.js");

  const {vaultAddr, strategyName} = await prompt.get(['vaultAddr', 'strategyName']);

  const StrategyImpl = artifacts.require(strategyName);
  const impl = await StrategyImpl.new();

  console.log("Implementation deployed at:", impl.address);

  const StrategyProxy = artifacts.require('StrategyProxy');
  const proxy = await StrategyProxy.new(impl.address);

  console.log("Proxy deployed at:", proxy.address);

  const strategy = await StrategyImpl.at(proxy.address);
  await type2Transaction(strategy.initializeStrategy, addresses.Storage, vaultAddr);

  console.log("Deployment complete. New strategy deployed and initialised at", proxy.address);
  const result = {}
  result.vault = vaultAddr
  result.strategy = proxy.address

  console.log(result)

  try {
    await hre.run("verify:verify", {address: impl.address}); 
  } catch (e) {
    console.log(e)
  }

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });