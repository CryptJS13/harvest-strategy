// Utilities
const Utils = require("../../utilities/Utils.js");
const {
  impersonates,
  setupCoreProtocol,
  depositVault,
} = require("../../utilities/hh-utils.js");

const addresses = require("../../test-config.js");
const BigNumber = require("bignumber.js");
const IERC20 = artifacts.require("IERC20");

const Strategy = artifacts.require("MorphoVaultStrategyMainnet_BW_AUSD_V2");

// Developed and tested at blockNumber 25933440

// Regression cover for the exit path: `withdrawAllToVault()` used to hand the vault every
// last unit of underlying, including the amount backing a `pendingFee` that `_handleFee`
// had left unpaid because it sat under `feeFloor()`. `investedUnderlyingBalance()` is
// `idle + stored - pendingFee`, so the strategy was then left reporting a negative balance
// and every vault entrypoint that reads it reverted.
//
// The deposit here is deliberately small and the wait short, so the fee accrued between
// harvests lands under the floor and stays pending - that is the branch being covered.
describe("Mainnet Morpho Vault V2 Bitwise Premium RWA AUSD exit paths", function() {
  let accounts;

  // external contracts
  let underlying;
  let farm;

  // external setup
  let underlyingWhale = "0x080f646713bce0da8c08770d407818de47639cf5";
  let ausd = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a";
  let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  let weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

  // parties in the protocol
  let governance;
  let farmer1;

  // numbers used in tests - small on purpose, see the note above
  let farmerBalance = new BigNumber(200e6).toFixed();

  // Core protocol contracts
  let controller;
  let vault;
  let strategy;

  async function setupExternalContracts() {
    underlying = await IERC20.at(ausd);
    farm = await IERC20.at(addresses.FARM);
    console.log("Fetching Underlying at: ", underlying.address);
  }

  async function setupBalance(){
    let etherGiver = accounts[9];
    await web3.eth.sendTransaction({ from: etherGiver, to: underlyingWhale, value: 10e18});
    await underlying.transfer(farmer1, farmerBalance, { from: underlyingWhale });
  }

  before(async function() {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();

    farmer1 = accounts[1];

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
      "liquidation": [
        {"uniV3": [ausd, usdc, weth]},
        {"uniV3": [weth, usdc, ausd]},
      ],
      "uniV3Fee": [
        [ausd, usdc, 100],
      ],
      "ULOwner": addresses.ULOwner,
    });

    await setupBalance();

    await depositVault(farmer1, underlying, vault, farmerBalance);
    await controller.doHardWork(vault.address, { from: governance });
  });

  describe("Exit paths", function() {
    it("Keeps an unpayable fee behind instead of bricking the vault", async function() {
      // a short wait on a small position leaves a fee under the floor, so it stays pending
      await Utils.waitHours(1);

      await strategy.withdrawAllToVault({ from: governance });

      const pendingFee = new BigNumber(await strategy.pendingFee());
      const idle = new BigNumber(await underlying.balanceOf(strategy.address));
      const invested = new BigNumber(await strategy.investedUnderlyingBalance());
      console.log("pending fee kept in the strategy: ", pendingFee.toFixed());
      console.log("idle underlying in the strategy:  ", idle.toFixed());
      console.log("investedUnderlyingBalance:        ", invested.toFixed());

      // the fee is genuinely unpaid and under the floor - this is the branch under test
      Utils.assertBNGt(pendingFee, 0);
      Utils.assertBNGte(new BigNumber(await strategy.feeFloor()), pendingFee);
      // and it is still backed by underlying the strategy actually holds
      Utils.assertBNGte(idle, pendingFee);

      // the vault is readable and usable, which is what used to break
      const sharePrice = new BigNumber(await vault.getPricePerFullShare());
      console.log("share price after the exit: ", sharePrice.toFixed());
      Utils.assertBNGt(sharePrice, 0);

      // the farmer gets the deposit back plus their share of the hour's yield, and the
      // fee left behind is not taken out of their principal
      const farmerBefore = new BigNumber(await underlying.balanceOf(farmer1));
      await vault.withdraw(new BigNumber(await vault.balanceOf(farmer1)).toFixed(), { from: farmer1 });
      const farmerAfter = new BigNumber(await underlying.balanceOf(farmer1));
      const withdrawn = farmerAfter.minus(farmerBefore);
      console.log("farmer withdrew: ", withdrawn.toFixed(), " deposited: ", farmerBalance);
      Utils.assertBNGte(withdrawn, new BigNumber(farmerBalance));
      // the gain is the hour of yield net of the fee, not a raid on the fee kept behind
      assert.equal(
        withdrawn.minus(farmerBalance).lte(1e4),
        true,
        "farmer should not withdraw more than the deposit plus the hour's yield"
      );
    });
  });
});
