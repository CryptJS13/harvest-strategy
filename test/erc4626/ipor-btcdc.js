// IPOR Fusion BTCdc (WBTC) on Ethereum, through HookVaultV2 + GeneralERC4626Strategy.
//
// BTCdc charges an off-boarding fee on every redemption (0.10% at the pinned block). The
// strategy redeems by shares so that fee comes out of the withdrawing user's own payout and
// is never socialised across the other holders - the second test pins that down.
//
// On a fork nothing rebalances the PlasmaVault, so its cached market balances do not
// accrue with simulated time. The happy path therefore does not assert "farmer earns
// money"; it asserts the stronger, fork-proof property that a farmer going through the
// Harvest vault ends up with what a depositor going straight into the PlasmaVault gets,
// minus only Harvest's fee on any profit.
//
// Developed and tested at blockNumber 25933440

const Utils = require("../utilities/Utils.js");
const { impersonates, setupCoreProtocol, depositVault } = require("../utilities/hh-utils.js");

const addresses = require("../test-config.js");
const BigNumber = require("bignumber.js");
const { ethers, network } = require("hardhat");

const IERC20 = artifacts.require("IERC20");
const IERC4626 = artifacts.require("contracts/base/interface/IERC4626.sol:IERC4626");
const HookVaultV2 = artifacts.require("HookVaultV2");
const Strategy = artifacts.require("IPORLendingStrategyMainnet_BTCdc");

const WBTC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";
const WBTC_BALANCES_SLOT = 0;
const FTOKEN = "0x7659fc26bf3A63E8133BbECB7E16ACD48EE8E292";

describe("Mainnet IPOR Lending BTCdc", function () {
  let accounts, governance, farmer1, farmer2, reference;
  let underlying, fToken, fTokenErc20;
  let controller, vault, strategy;

  // Write straight into WBTC's balances mapping - no whale needed.
  async function fund(who, amount) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [who, WBTC_BALANCES_SLOT]));
    await network.provider.send("hardhat_setStorageAt", [WBTC, key, ethers.utils.hexZeroPad(ethers.BigNumber.from(amount).toHexString(), 32)]);
  }

  // Ratios are done in plain numbers: Utils.js configures bignumber.js with DECIMAL_PLACES 0,
  // so a fractional BigNumber division rounds to an integer. Every value here is < 2^53.
  const num = (x) => Number(new BigNumber(x).toFixed());

  // The PlasmaVault's own exit fee, measured: previewRedeem is net of it, convertToAssets is not.
  async function iporExitFee() {
    const probe = "1000000000000";
    const gross = num(await fToken.convertToAssets(probe));
    const net = num(await fToken.previewRedeem(probe));
    return (gross - net) / gross;
  }

  // Share price at full precision; getPricePerFullShare() is truncated to the underlying's decimals.
  async function pricePerShare() {
    return num(await vault.underlyingBalanceWithInvestment()) / num(await vault.totalSupply());
  }

  // A fresh vault and strategy. Each group of tests that changes the vault's configuration
  // or drains it takes its own, so the groups do not depend on each other's leftovers.
  async function deploy() {
    const vaultImpl = await HookVaultV2.new({ from: governance });
    [controller, vault, strategy] = await setupCoreProtocol({
      "existingVaultAddress": null,
      "vaultImplementationOverride": vaultImpl.address,
      "strategyArtifact": Strategy,
      "strategyArtifactIsUpgradable": true,
      "underlying": underlying,
      "governance": governance,
    });
    vault = await HookVaultV2.at(vault.address);
  }

  before(async function () {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();
    farmer1 = accounts[1];
    farmer2 = accounts[2];
    reference = accounts[3];

    await impersonates([governance]);
    await web3.eth.sendTransaction({ from: accounts[9], to: governance, value: 10e18 });

    underlying = await IERC20.at(WBTC);
    fToken = await IERC4626.at(FTOKEN);
    fTokenErc20 = await IERC20.at(FTOKEN);
    console.log("Fetching Underlying at: ", underlying.address);

    await deploy();

    await fund(farmer1, "90000000");   // 0.9 WBTC
    await fund(farmer2, "10000000");   // 0.1 WBTC
    await fund(reference, "90000000");
  });

  describe("Happy path", function () {
    it("Farmer gets what a direct PlasmaVault depositor gets, minus only Harvest's fee on profit", async function () {
      const principal = new BigNumber(await underlying.balanceOf(farmer1));
      await depositVault(farmer1, underlying, vault, principal.toFixed());

      // The reference enters the PlasmaVault in the same block the strategy does (the
      // first hard work is what deploys the deposit).
      await underlying.approve(FTOKEN, principal.toFixed(), { from: reference });
      await fToken.deposit(principal.toFixed(), reference, { from: reference });

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

        await Utils.advanceNBlock(blocksPerHour);
      }

      // The PlasmaVault keeps a redeemer's exit fee, so whoever redeems second collects a
      // slice of the first one's fee. Measure the two exits from the same state.
      const snapshot = await network.provider.send("evm_snapshot");
      await fToken.redeem(new BigNumber(await fTokenErc20.balanceOf(reference)).toFixed(), reference, reference, { from: reference });
      const referenceGot = new BigNumber(await underlying.balanceOf(reference));
      await network.provider.send("evm_revert", [snapshot]);

      await vault.withdraw(new BigNumber(await vault.balanceOf(farmer1)).toFixed(), { from: farmer1 });
      const farmerGot = new BigNumber(await underlying.balanceOf(farmer1));

      const gain = BigNumber.max(referenceGot.minus(principal), 0);
      const harvestFee = gain
        .times(await strategy.totalFeeNumerator())
        .idiv(await strategy.feeDenominator())
        .plus(1);

      console.log("principal      ", principal.toFixed());
      console.log("via Harvest    ", farmerGot.toFixed());
      console.log("direct to IPOR ", referenceGot.toFixed(), "(Harvest fee on the profit:", harvestFee.toFixed() + ")");
      console.log("difference     ", farmerGot.minus(referenceGot).toFixed());

      // Rounding: a couple of units across two share conversions and the exit fee.
      const rounding = referenceGot.idiv(1000000).plus(1);
      Utils.assertBNGte(farmerGot, referenceGot.minus(harvestFee).minus(rounding));
      // And the wrapper never gives away more than IPOR does.
      Utils.assertBNGte(referenceGot.plus(rounding), farmerGot);

      await strategy.withdrawAllToVault({ from: governance }); // making sure can withdraw all for a next switch
    });
  });

  describe("Exit fee attribution", function () {
    it("charges the PlasmaVault's exit fee to the withdrawing user only", async function () {
      await depositVault(farmer1, underlying, vault, new BigNumber(await underlying.balanceOf(farmer1)).toFixed());
      await depositVault(farmer2, underlying, vault, new BigNumber(await underlying.balanceOf(farmer2)).toFixed());
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine"); // clear the redemption lock the deposit armed

      const fee = await iporExitFee();
      const probe = "1000000000000";
      const iporPps0 = num(await fToken.convertToAssets(probe));
      const pps0 = await pricePerShare();
      const entitlement = num(await vault.underlyingBalanceWithInvestmentForHolder(farmer2));
      const shares = new BigNumber(await vault.balanceOf(farmer2)).toFixed();
      console.log("  IPOR exit fee      ", (fee * 100).toFixed(4) + "%");
      console.log("  farmer2 entitlement", entitlement);

      const before = num(await underlying.balanceOf(farmer2));
      await vault.withdraw(shares, { from: farmer2 });
      const got = num(await underlying.balanceOf(farmer2)) - before;

      const pps1 = await pricePerShare();
      const iporPps1 = num(await fToken.convertToAssets(probe));
      const ipor = iporPps1 / iporPps0;
      const bystander = pps1 / pps0;
      // The PlasmaVault refreshes its market balances on a redemption. Whatever that does
      // to its own share price legitimately reaches every Harvest holder (net of Harvest's
      // fee on a gain); the exit fee must not.
      const totalFee = num(await strategy.totalFeeNumerator()) / num(await strategy.feeDenominator());
      const expected = ipor > 1 ? 1 + (ipor - 1) * (1 - totalFee) : ipor;

      console.log("  farmer2 received   ", got, "=", (got / entitlement * 100).toFixed(4) + "% of entitlement");
      console.log("  IPOR pps ratio     ", ipor.toFixed(8));
      console.log("  bystander pps ratio", bystander.toFixed(8), "(expected >=", expected.toFixed(8) + ")");

      // Socialising the fee would cost the bystanders fee x farmer2's share of supply
      // (~0.01% here); the tolerance is an order of magnitude below that.
      assert.isTrue(bystander >= expected * (1 - 2e-5), "the exit fee leaked onto the remaining holders");
      // The withdrawer paid the fee, and nothing beyond the fee and IPOR's own revaluation.
      assert.isTrue(got <= entitlement * (1 - fee) * (1 + 1e-4), "the withdrawer did not pay the exit fee");
      assert.isTrue(got >= entitlement * (1 - fee) * ipor * (1 - 1e-4), "the withdrawer was charged more than the exit fee");
    });
  });
  describe("Fee handling", function () {
    // A position increase that is small enough for the accrued fee to fall under
    // _handleFee's 1e3 dust floor. On 8-decimal WBTC that is only ~6,700 sat of gain, so
    // it is an ordinary inter-harvest move rather than a corner case.
    async function accrueDustFee() {
      const numerator = num(await strategy.totalFeeNumerator());
      const denominator = num(await strategy.feeDenominator());
      // Sized off whatever gap is already there, so the accrued fee lands comfortably under
      // the 1e3 floor regardless of what the PlasmaVault's last refresh did.
      const gap = Math.max(num(await strategy.currentBalance()) - num(await strategy.storedBalance()), 0);
      const increase = Math.max(Math.floor(500 * denominator / numerator) - gap, 0);
      if (increase > 0) {
        await underlying.approve(FTOKEN, String(increase), { from: reference });
        await fToken.deposit(String(increase), strategy.address, { from: reference });
        await network.provider.send("evm_mine"); // clear the lock the donation armed
      }
      await strategy.doHardWork({ from: governance });
      return num(await strategy.pendingFee());
    }

    it("a full exit still works when the accrued fee is below the dust floor", async function () {
      await fund(farmer1, "90000000");
      await fund(reference, "90000000");
      await depositVault(farmer1, underlying, vault, "90000000");
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");

      const dust = await accrueDustFee();
      console.log("  pendingFee below the dust floor:", dust);
      assert.isTrue(dust > 0 && dust <= 1000, "precondition: an unpayable dust fee must be pending, got " + dust);

      // The whole supply leaves, so the vault drains the strategy completely. The fee has
      // to stay behind it, or investedUnderlyingBalance() underflows and the exit reverts.
      const before = num(await underlying.balanceOf(farmer1));
      await vault.withdraw((await vault.balanceOf(farmer1)).toString(), { from: farmer1 });
      const got = num(await underlying.balanceOf(farmer1)) - before;
      console.log("  farmer1 exited with", got, "| strategy reports", num(await strategy.investedUnderlyingBalance()));

      assert.isTrue(got > 0, "the sole holder must be able to exit");
      assert.equal((await vault.balanceOf(farmer1)).toString(), "0");
      assert.equal(num(await strategy.investedUnderlyingBalance()), 0);
      // And the vault is still usable afterwards, rather than reverting on every view.
      assert.isTrue(num(await vault.getPricePerFullShare()) > 0);
    });

    it("governance draining the strategy leaves the vault usable", async function () {
      await fund(farmer1, "90000000");
      await fund(reference, "90000000");
      await depositVault(farmer1, underlying, vault, "90000000");
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");
      const dust = await accrueDustFee();
      console.log("  pendingFee below the dust floor:", dust);
      assert.isTrue(dust > 0 && dust <= 1000, "precondition: an unpayable dust fee must be pending, got " + dust);

      await vault.withdrawAll({ from: governance });
      console.log("  after withdrawAll - strategy idle", num(await underlying.balanceOf(strategy.address)),
                  "pendingFee", num(await strategy.pendingFee()),
                  "reported", num(await strategy.investedUnderlyingBalance()));
      assert.isTrue(num(await vault.getPricePerFullShare()) > 0, "share price must not revert after a drain");

      const before = num(await underlying.balanceOf(farmer1));
      await vault.withdraw((await vault.balanceOf(farmer1)).toString(), { from: farmer1 });
      assert.isTrue(num(await underlying.balanceOf(farmer1)) > before, "holders must still be able to exit");
    });

    it("forwards a payable fee to the reward forwarder", async function () {
      await fund(farmer1, "90000000");
      await fund(reference, "90000000");
      await depositVault(farmer1, underlying, vault, "90000000");
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");

      // Well above the dust floor, so _handleFee redeems it and hands it to the forwarder.
      await underlying.approve(FTOKEN, "1000000", { from: reference });
      await fToken.deposit("1000000", strategy.address, { from: reference });
      await network.provider.send("evm_mine");

      await strategy.doHardWork({ from: governance });
      const pending = num(await strategy.pendingFee());
      console.log("  pendingFee after the harvest:", pending);
      assert.isTrue(pending <= 1000, "the fee must have been paid out, not left pending");
    });
  });
});
