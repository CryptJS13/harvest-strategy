// Utilities
const Utils = require("../utilities/Utils.js");
const {
  impersonates,
  setupCoreProtocol,
  depositVault,
} = require("../utilities/hh-utils.js");

const addresses = require("../test-config.js");
const BigNumber = require("bignumber.js");
const IERC20 = artifacts.require("IERC20");

const Strategy = artifacts.require("InactiveVaultERC4626StrategyMainnet_USDC");

// Developed and tested at blockNumber 23489150

// Vanilla Mocha test. Increased compatibility with tools that integrate Mocha.
describe("Mainnet Inactive Vault ERC4626 USDC exit paths", function() {
  let accounts;

  // external contracts
  let underlying;
  let farm;
  let erc4626Vault = "0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458";

  // external setup
  let underlyingWhale = "0x072a452Eb96f4CD3458473754d23B86eEe4E8bDf";

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
    underlying = await IERC20.at("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
    farm = await IERC20.at(addresses.FARM);
    console.log("Fetching Underlying at: ", underlying.address);
  }

  async function setupBalance(){
    let etherGiver = accounts[9];
    await web3.eth.sendTransaction({ from: etherGiver, to: underlyingWhale, value: 10e18});

    farmerBalance = await underlying.balanceOf(underlyingWhale);
    await underlying.transfer(farmer1, farmerBalance, { from: underlyingWhale });
  }

  before(async function() {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();

    farmer1 = accounts[1];

    // impersonate accounts
    await impersonates([governance, underlyingWhale, addresses.ULOwner]);

    let etherGiver = accounts[9];
    await web3.eth.sendTransaction({ from: etherGiver, to: governance, value: 10e18});
    await web3.eth.sendTransaction({ from: etherGiver, to: addresses.ULOwner, value: 10e18});

    await setupExternalContracts();
    [controller, vault, strategy] = await setupCoreProtocol({
      "existingVaultAddress": null,
      "strategyArtifact": Strategy,
      "strategyArtifactIsUpgradable": true,
      "underlying": underlying,
      "governance": governance,
      "ULOwner": addresses.ULOwner,
    });

    // whale send underlying to farmers
    await setupBalance();

    await depositVault(farmer1, underlying, vault, farmerBalance);
    await controller.doHardWork(vault.address, { from: governance });
  });

  describe("Exit paths", function() {
    it("Emergency exit keeps the depositor funds and the accrued fee separate", async function() {
      await Utils.waitHours(24);

      const investedBefore = new BigNumber(await strategy.investedUnderlyingBalance());
      const sharePriceBefore = new BigNumber(await vault.getPricePerFullShare());

      await strategy.emergencyExit({ from: governance });

      const pendingFee = new BigNumber(await strategy.pendingFee());
      const invested = new BigNumber(await strategy.investedUnderlyingBalance());
      const idle = new BigNumber(await underlying.balanceOf(strategy.address));
      const inErc4626 = new BigNumber(await (await IERC20.at(erc4626Vault)).balanceOf(strategy.address));
      console.log("pending fee after emergency exit: ", pendingFee.toFixed());
      console.log("idle underlying:                  ", idle.toFixed());

      // a day of yield has been accrued as fee, and everything is out of the ERC4626 vault
      console.log("shares left in the erc4626 vault:  ", inErc4626.toFixed());
      Utils.assertBNGt(pendingFee, 0);
      Utils.assertBNGte(1e3, inErc4626);
      assert.equal(await strategy.pausedInvesting(), true, "investing should be paused");
      // the fee is not part of what the depositors own
      Utils.assertBNEq(invested, idle.minus(pendingFee));
      Utils.assertBNGte(investedBefore.plus(10), invested);
      // and the share price did not move
      const sharePriceAfter = new BigNumber(await vault.getPricePerFullShare());
      Utils.assertBNGte(sharePriceBefore.plus(10), sharePriceAfter);
      Utils.assertBNGte(sharePriceAfter.plus(10), sharePriceBefore);

      // the fee is paid out and the funds are invested again once investing continues
      const oldProfitShare = new BigNumber(await farm.balanceOf(await controller.profitSharingReceiver()));
      await strategy.continueInvesting({ from: governance });
      await controller.doHardWork(vault.address, { from: governance });

      const newProfitShare = new BigNumber(await farm.balanceOf(await controller.profitSharingReceiver()));
      console.log("profit sharing gain (FARM): ", newProfitShare.minus(oldProfitShare).toFixed());
      Utils.assertBNGt(newProfitShare, oldProfitShare);
      Utils.assertBNGte(100, new BigNumber(await strategy.pendingFee()));
      Utils.assertBNGt(new BigNumber(await (await IERC20.at(erc4626Vault)).balanceOf(strategy.address)), 0);
    });

    it("Can be exited to the vault with the fee liquidation disabled", async function() {
      await Utils.waitHours(24);

      // fee liquidation off: the exit must not depend on the liquidator working
      await strategy.setSell(false, { from: governance });
      await strategy.withdrawAllToVault({ from: governance });

      const pendingFee = new BigNumber(await strategy.pendingFee());
      const idle = new BigNumber(await underlying.balanceOf(strategy.address));
      console.log("pending fee kept in the strategy: ", pendingFee.toFixed());
      console.log("idle underlying in the strategy:  ", idle.toFixed());

      // the accrued fee stays behind, everything else went to the vault
      Utils.assertBNGt(pendingFee, 0);
      Utils.assertBNGte(idle, pendingFee);
      Utils.assertBNGte(1e3, new BigNumber(await strategy.investedUnderlyingBalance()));

      // the farmer gets the deposit back, without any yield
      const farmerBefore = new BigNumber(await underlying.balanceOf(farmer1));
      await vault.withdraw(new BigNumber(await vault.balanceOf(farmer1)).toFixed(), { from: farmer1 });
      const farmerAfter = new BigNumber(await underlying.balanceOf(farmer1));
      const withdrawn = farmerAfter.minus(farmerBefore);
      console.log("farmer withdrew: ", withdrawn.toFixed(), " deposited: ", new BigNumber(farmerBalance).toFixed());
      Utils.assertBNGte(new BigNumber(farmerBalance), withdrawn);
      assert.equal(new BigNumber(farmerBalance).minus(withdrawn).lte(1e6), true, "farmer should get the deposit back");

      // the fee left behind can still be collected afterwards
      const oldProfitShare = new BigNumber(await farm.balanceOf(await controller.profitSharingReceiver()));
      await strategy.setSell(true, { from: governance });
      await strategy.doHardWork({ from: governance });
      const newProfitShare = new BigNumber(await farm.balanceOf(await controller.profitSharingReceiver()));
      console.log("profit sharing gain (FARM): ", newProfitShare.minus(oldProfitShare).toFixed());
      Utils.assertBNGt(newProfitShare, oldProfitShare);
      Utils.assertBNGte(100, new BigNumber(await strategy.pendingFee()));
    });
  });
});
