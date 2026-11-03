// Utilities
const Utils = require("../utilities/Utils.js");
const { impersonates, setupCoreProtocol, depositVault } = require("../utilities/hh-utils.js");
const addresses = require("../test-config.js");

const BigNumber = require("bignumber.js");
const IERC20 = artifacts.require("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20");

const Strategy = artifacts.require("ConvexLendStrategyMainnet_crvUSD_sUSDS");
const IBooster = artifacts.require("IBooster");

//This test was developed at blockNumber 22267000

// Vanilla Mocha test. Increased compatibility with tools that integrate Mocha.
describe("Mainnet Convex Curve Lend crvUSD sUSDS", function() {
  let accounts;

  // external contracts
  let underlying;

  // external setup
  let underlyingWhale = "0xE535b101a990f2Cc37893B774c8e5002A4699659";
  let crv = "0xD533a949740bb3306d119CC777fa900bA034cd52";

  // parties in the protocol
  let governance;
  let farmer1;

  // numbers used in tests
  let farmerBalance;

  // Core protocol contracts
  let controller;
  let vault;
  let strategy;

  async function setupExternalContracts() {
    underlying = await IERC20.at("0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E");
    console.log("Fetching Underlying at: ", underlying.address);
  }

  async function setupBalance(){
    let etherGiver = accounts[9];
    // Give whale some ether to make sure the following actions are good
    await web3.eth.sendTransaction({ from: etherGiver, to: underlyingWhale, value: 10e18});

    farmerBalance = await underlying.balanceOf(underlyingWhale);
    await underlying.transfer(farmer1, farmerBalance, { from: underlyingWhale });
  }

  before(async function() {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();

    await web3.eth.sendTransaction({ from: accounts[8], to: governance, value: 10e18});

    farmer1 = accounts[1];

    // impersonate accounts
    await impersonates([governance, underlyingWhale]);

    await setupExternalContracts();
    [controller, vault, strategy] = await setupCoreProtocol({
      "existingVaultAddress": null,
      "strategyArtifact": Strategy,
      "strategyArtifactIsUpgradable": true,
      "underlying": underlying,
      "governance": governance,
      "liquidation": [
        {"curve": [crv, underlying.address]},
      ],
      "curveSetup": [
        [crv, underlying.address, "0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14", [2, 0, 1, 3, 3]],
      ]
    });

    // whale send underlying to farmers
    await setupBalance();

    // const booster = await IBooster.at("0xF403C135812408BFbE8713b5A23a04b3D48AAE31");
    // await booster.earmarkRewards(await strategy.poolId());
  });

  describe("Happy path", function() {
    it("Farmer should earn money", async function() {
      let farmerOldBalance = new BigNumber(await underlying.balanceOf(farmer1));
      await depositVault(farmer1, underlying, vault, farmerBalance);
      let fTokenBalance = new BigNumber(await vault.balanceOf(farmer1));

      // Using half days is to simulate how we doHardwork in the real world
      let hours = 10;
      let blocksPerHour = 2400;
      let oldSharePrice;
      let newSharePrice;
      for (let i = 0; i < hours; i++) {
        console.log("loop ", i);

        oldSharePrice = new BigNumber(await vault.getPricePerFullShare());
        await controller.doHardWork(vault.address, { from: governance });
        newSharePrice = new BigNumber(await vault.getPricePerFullShare());

        console.log("old shareprice: ", oldSharePrice.toFixed());
        console.log("new shareprice: ", newSharePrice.toFixed());
        console.log("growth: ", newSharePrice.toFixed() / oldSharePrice.toFixed());

        apr = (newSharePrice.toFixed()/oldSharePrice.toFixed()-1)*(24/(blocksPerHour/300))*365;
        apy = ((newSharePrice.toFixed()/oldSharePrice.toFixed()-1)*(24/(blocksPerHour/300))+1)**365;

        console.log("instant APR:", apr*100, "%");
        console.log("instant APY:", (apy-1)*100, "%");
        await vault.withdraw(fTokenBalance.div(10), { from: farmer1 });
        await depositVault(farmer1, underlying, vault, new BigNumber(await underlying.balanceOf(farmer1)))
        await Utils.advanceNBlock(blocksPerHour);
      }
      fTokenBalance = new BigNumber(await vault.balanceOf(farmer1));
      await vault.withdraw(fTokenBalance, { from: farmer1 });
      let farmerNewBalance = new BigNumber(await underlying.balanceOf(farmer1));
      Utils.assertBNGt(farmerNewBalance, farmerOldBalance);

      apr = (farmerNewBalance.toFixed()/farmerOldBalance.toFixed()-1)*(24/(blocksPerHour*hours/300))*365;
      apy = ((farmerNewBalance.toFixed()/farmerOldBalance.toFixed()-1)*(24/(blocksPerHour*hours/300))+1)**365;

      console.log("earned!");
      console.log("Overall APR:", apr*100, "%");
      console.log("Overall APY:", (apy-1)*100, "%");

      await strategy.withdrawAllToVault({ from: governance }); // making sure can withdraw all for a next switch
    });
  });
});