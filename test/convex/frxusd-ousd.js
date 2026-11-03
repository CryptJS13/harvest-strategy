// Utilities
const Utils = require("../utilities/Utils.js");
const {
  impersonates,
  setupCoreProtocol,
  depositVault,
} = require("../utilities/hh-utils.js");
const addresses = require("../test-config.js");

const BigNumber = require("bignumber.js");
const IERC20 = artifacts.require(
  "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20"
);

const Strategy = artifacts.require("ConvexStrategyMainnet_frxUSD_OUSD");

//This test was developed at blockNumber 24448000

// Vanilla Mocha test. Increased compatibility with tools that integrate Mocha.
describe("Mainnet Convex frxUSD-OUSD", function () {
  let accounts;

  // external contracts
  let underlying;

  // external setup
  let underlyingWhale = "0xa9BdADCE387700B18a3D5c2a668395bDAdc7b76B";
  let crv = "0xD533a949740bb3306d119CC777fa900bA034cd52";
  let cvx = "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B";
  let weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  let crvusd = "0xf939e0a03fb07f59a73314e73794be0e57ac1b4e";
  let frxusd = "0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29";

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
    underlying = await IERC20.at("0x68d03Ed49800e92D7Aa8aB171424007e55Fd1F49");
    console.log("Fetching Underlying at: ", underlying.address);
  }

  async function setupBalance() {
    let etherGiver = accounts[9];
    // Give whale some ether to make sure the following actions are good
    await web3.eth.sendTransaction({
      from: etherGiver,
      to: underlyingWhale,
      value: 10e18,
    });

    farmerBalance = await underlying.balanceOf(underlyingWhale);
    await underlying.transfer(farmer1, farmerBalance, {
      from: underlyingWhale,
    });
  }

  before(async function () {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();

    await web3.eth.sendTransaction({
      from: accounts[8],
      to: governance,
      value: 10e18,
    });

    await web3.eth.sendTransaction({
      from: accounts[8],
      to: addresses.ULOwner,
      value: 10e18,
    });

    farmer1 = accounts[1];

    // impersonate accounts
    await impersonates([governance, underlyingWhale, addresses.ULOwner]);

    await setupExternalContracts();
    [controller, vault, strategy] = await setupCoreProtocol({
      existingVaultAddress: null,
      strategyArtifact: Strategy,
      strategyArtifactIsUpgradable: true,
      underlying: underlying,
      governance: governance,
      liquidation: [
        // { uniV3: [cvx, weth] },
        // { uniV3: [crv, weth] },
        { curve: [weth, crvusd, frxusd] },
      ],
      // uniV3Fee: [
      //   [weth, crv, "3000"],
      //   [weth, cvx, "10000"],
      // ],
      curveSetup: [
        // [
        //   weth,
        //   crvusd,
        //   "0x4ebdf703948ddcea3b11f675b4d1fba9d2414a14",
        //   [1, 0, 1, 3, 3],
        // ],
        [
          crvusd,
          frxusd,
          "0x13e12bb0e6a2f1a3d6901a59a9d585e89a6243e1",
          [1, 0, 1, 10, 2],
        ],
      ],
      // ULOwner: addresses.ULOwner,
    });

    // whale send underlying to farmers
    await setupBalance();
  });

  describe("Happy path", function () {
    it("Farmer should earn money", async function () {
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
        console.log(
          "growth: ",
          newSharePrice.toFixed() / oldSharePrice.toFixed()
        );

        apr =
          (newSharePrice.toFixed() / oldSharePrice.toFixed() - 1) *
          (24 / (blocksPerHour / 300)) *
          365;
        apy =
          ((newSharePrice.toFixed() / oldSharePrice.toFixed() - 1) *
            (24 / (blocksPerHour / 300)) +
            1) **
          365;

        console.log("instant APR:", apr * 100, "%");
        console.log("instant APY:", (apy - 1) * 100, "%");
        await vault.withdraw(fTokenBalance.div(10), { from: farmer1 });
        await depositVault(
          farmer1,
          underlying,
          vault,
          new BigNumber(await underlying.balanceOf(farmer1))
        );
        await Utils.advanceNBlock(blocksPerHour);
      }
      fTokenBalance = new BigNumber(await vault.balanceOf(farmer1));
      await vault.withdraw(fTokenBalance, { from: farmer1 });
      let farmerNewBalance = new BigNumber(await underlying.balanceOf(farmer1));
      Utils.assertBNGt(farmerNewBalance, farmerOldBalance);

      apr =
        (farmerNewBalance.toFixed() / farmerOldBalance.toFixed() - 1) *
        (24 / ((blocksPerHour * hours) / 300)) *
        365;
      apy =
        ((farmerNewBalance.toFixed() / farmerOldBalance.toFixed() - 1) *
          (24 / ((blocksPerHour * hours) / 300)) +
          1) **
        365;

      console.log("earned!");
      console.log("Overall APR:", apr * 100, "%");
      console.log("Overall APY:", (apy - 1) * 100, "%");

      await strategy.withdrawAllToVault({ from: governance }); // making sure can withdraw all for a next switch
    });
  });
});
