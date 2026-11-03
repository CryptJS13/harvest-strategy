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
const IERC4626 = artifacts.require("contracts/base/interface/IERC4626.sol:IERC4626");

const Strategy = artifacts.require("InactiveVaultERC4626StrategyMainnet_USDC");

// Developed and tested at blockNumber 23489150

// Vanilla Mocha test. Increased compatibility with tools that integrate Mocha.
describe("Mainnet Inactive Vault ERC4626 USDC", function() {
  let accounts;

  // external contracts
  let underlying;
  let farm;
  let weth;
  let erc4626Vault;

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
    weth = await IERC20.at(addresses.WETH);
    // the plain ERC4626 vault the strategy parks the funds in
    erc4626Vault = await IERC4626.at("0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458");
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
  });

  describe("Happy path", function() {
    it("Farmer should not earn, all yield should be taken as fee", async function() {
      let farmerOldBalance = new BigNumber(await underlying.balanceOf(farmer1));
      await depositVault(farmer1, underlying, vault, farmerBalance);

      const profitSharingReceiver = await controller.profitSharingReceiver();
      const protocolFeeReceiver = await controller.protocolFeeReceiver();
      const oldProfitShare = new BigNumber(await farm.balanceOf(profitSharingReceiver));
      const oldPlatformShare = new BigNumber(await weth.balanceOf(protocolFeeReceiver));
      // the price per share of the ERC4626 vault we invest in, to show that it does yield
      const oldErc4626Price = new BigNumber(await erc4626Vault.convertToAssets("1000000000000000000"));

      let hours = 10;
      let blocksPerHour = 2400;
      let oldSharePrice;
      let newSharePrice;

      // the vault is inactive: the share price has to stay flat over the whole period
      const initialSharePrice = new BigNumber(await vault.getPricePerFullShare());
      // tolerance of 1e-5 of the share price, to allow for rounding dust
      const sharePriceTolerance = initialSharePrice.div(1e5);

      for (let i = 0; i < hours; i++) {
        console.log("loop ", i);

        oldSharePrice = new BigNumber(await vault.getPricePerFullShare());
        await controller.doHardWork(vault.address, { from: governance });
        newSharePrice = new BigNumber(await vault.getPricePerFullShare());

        console.log("old shareprice: ", oldSharePrice.toFixed());
        console.log("new shareprice: ", newSharePrice.toFixed());
        console.log("pending fee:    ", new BigNumber(await strategy.pendingFee()).toFixed());

        // no yield may reach the depositors, only dust from rounding is tolerated
        let drift = newSharePrice.minus(initialSharePrice).abs();
        assert.equal(drift.lte(sharePriceTolerance), true,
          "share price moved by " + drift.toFixed() + ", started at " + initialSharePrice.toFixed());

        await Utils.advanceNBlock(blocksPerHour);
      }

      // the ERC4626 vault the funds are parked in did produce yield over the period
      const newErc4626Price = new BigNumber(await erc4626Vault.convertToAssets("1000000000000000000"));
      console.log("erc4626 price per share: ", oldErc4626Price.toFixed(), "->", newErc4626Price.toFixed());
      Utils.assertBNGt(newErc4626Price, oldErc4626Price);

      // and all of that yield was collected as fee and forwarded to the fee recipients
      const newProfitShare = new BigNumber(await farm.balanceOf(profitSharingReceiver));
      const newPlatformShare = new BigNumber(await weth.balanceOf(protocolFeeReceiver));
      console.log("profit sharing gain (FARM): ", newProfitShare.minus(oldProfitShare).toFixed());
      console.log("platform fee gain (WETH):   ", newPlatformShare.minus(oldPlatformShare).toFixed());
      Utils.assertBNGt(newProfitShare, oldProfitShare);
      Utils.assertBNGt(newPlatformShare, oldPlatformShare);

      // the fee log shows the full yield being charged as fee
      const feeLogs = await strategy.getPastEvents("PlatformFeeLogInReward", { fromBlock: 0, toBlock: "latest" });
      let platformFeeTotal = new BigNumber(0);
      let chargedProfitTotal = new BigNumber(0);
      for (const feeLog of feeLogs) {
        platformFeeTotal = platformFeeTotal.plus(feeLog.args.feeAmount);
        chargedProfitTotal = chargedProfitTotal.plus(feeLog.args.profitAmount);
      }
      console.log("yield charged as fee (USDC): ", chargedProfitTotal.toFixed());
      console.log("platform fee (USDC):         ", platformFeeTotal.toFixed());
      Utils.assertBNGt(chargedProfitTotal, 0);
      // the whole charged profit is fee: platform gets platformFeeNumerator / totalFeeNumerator of it
      const totalFeeNumerator = new BigNumber(await strategy.totalFeeNumerator());
      const platformFeeNumerator = new BigNumber(await controller.platformFeeNumerator());
      const expectedPlatformFee = chargedProfitTotal.times(platformFeeNumerator).div(totalFeeNumerator);
      const feeSplitDiff = platformFeeTotal.minus(expectedPlatformFee).abs();
      assert.equal(feeSplitDiff.lte(1e3), true,
        "platform fee " + platformFeeTotal.toFixed() + " does not match the expected split " + expectedPlatformFee.toFixed());

      // nothing meaningful is left pending in the strategy
      console.log("pending fee left: ", new BigNumber(await strategy.pendingFee()).toFixed());

      await vault.withdraw(new BigNumber(await vault.balanceOf(farmer1)).toFixed(), { from: farmer1 });
      let farmerNewBalance = new BigNumber(await underlying.balanceOf(farmer1));
      console.log("farmer old balance: ", farmerOldBalance.toFixed());
      console.log("farmer new balance: ", farmerNewBalance.toFixed());

      // the farmer gets the deposit back, without any yield
      let balanceDiff = farmerNewBalance.minus(farmerOldBalance).abs();
      assert.equal(balanceDiff.lte(farmerOldBalance.div(1e5)), true,
        "farmer balance moved by " + balanceDiff.toFixed());
      Utils.assertBNGte(farmerOldBalance, farmerNewBalance);

      await strategy.withdrawAllToVault({from: governance}); // making sure can withdraw all for a next switch
    });
  });
});
