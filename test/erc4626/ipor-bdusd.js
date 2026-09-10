// IPOR Fusion bdUSD (USDC) on Ethereum, through HookVaultV2 + GeneralERC4626Strategy.
//
// bdUSD charges an off-boarding fee on every redemption (0.20% at the pinned block). The
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
const Strategy = artifacts.require("IPORLendingStrategyMainnet_bdUSD");

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_BALANCES_SLOT = 9;
const FTOKEN = "0xF8F226dA66244F89e70C5B5D1a5C5b0d505Eb1d8";

describe("Mainnet IPOR Lending bdUSD", function () {
  let accounts, governance, farmer1, farmer2, reference;
  let underlying, fToken, fTokenErc20;
  let controller, vault, strategy;

  // Write straight into USDC's balances mapping - no whale needed.
  async function fund(who, amount) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [who, USDC_BALANCES_SLOT]));
    await network.provider.send("hardhat_setStorageAt", [USDC, key, ethers.utils.hexZeroPad(ethers.BigNumber.from(amount).toHexString(), 32)]);
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

    underlying = await IERC20.at(USDC);
    fToken = await IERC4626.at(FTOKEN);
    fTokenErc20 = await IERC20.at(FTOKEN);
    console.log("Fetching Underlying at: ", underlying.address);

    await deploy();

    await fund(farmer1, "90000000000");   // 90,000 USDC
    await fund(farmer2, "10000000000");   // 10,000 USDC
    await fund(reference, "90000000000");
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

  describe("Performance fee high water mark", function () {
    let sink;

    // Move PlasmaVault shares in and out of the strategy to simulate the position losing
    // and regaining value. The PlasmaVault caches its market balances, so simulated time
    // does not move `currentBalance()` on a fork; moving shares does, deterministically,
    // and is what a NAV change looks like to the strategy.
    async function moveShares(from, to, shares) {
      await impersonates([from]);
      await web3.eth.sendTransaction({ from: accounts[9], to: from, value: 1e18 });
      await fTokenErc20.transfer(to, shares, { from: from });
      await network.provider.send("evm_mine"); // a transfer arms the redemption lock
    }

    before(async function () {
      await deploy();
      sink = accounts[8];
      await fund(farmer1, "90000000000");
      await depositVault(farmer1, underlying, vault, "90000000000");
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");
      await strategy.doHardWork({ from: governance }); // settle any fee from going in
    });

    it("charges the fee on a gain", async function () {
      const before = num(await strategy.pendingFee());
      const gain = num(await strategy.currentBalance()) * 0.02;
      await fund(reference, "5000000000");
      await underlying.approve(FTOKEN, String(Math.round(gain)), { from: reference });
      await fToken.deposit(String(Math.round(gain)), strategy.address, { from: reference });
      await network.provider.send("evm_mine");

      await strategy.doHardWork({ from: governance });
      console.log("  pendingFee", before, "->", num(await strategy.pendingFee()), "| lossCarry", num(await strategy.lossCarry()));
      assert.equal(num(await strategy.lossCarry()), 0, "a gain must not create a loss carry");
    });

    it("records a loss instead of charging anything, then waives the fee on earning it back", async function () {
      const peak = num(await strategy.currentBalance());
      const heldShares = new BigNumber(await fTokenErc20.balanceOf(strategy.address));
      const moved = heldShares.idiv(20).toFixed(); // ~5% of the position

      // --- the dip ---
      await moveShares(strategy.address, sink, moved);
      const dipped = num(await strategy.currentBalance());
      const feeBeforeDip = num(await strategy.pendingFee());
      await strategy.doHardWork({ from: governance });
      const carry = num(await strategy.lossCarry());
      console.log("  position", peak, "->", dipped, "| lossCarry", carry, "| pendingFee", feeBeforeDip, "->", num(await strategy.pendingFee()));
      assert.isTrue(carry > 0, "the loss must be carried");
      assert.approximately(carry / (peak - dipped), 1, 0.01, "the whole loss must be carried");
      assert.equal(num(await strategy.pendingFee()), feeBeforeDip, "a loss must not accrue a fee");

      // --- earning it back: this is what a snapshot mark would charge for ---
      const feeBeforeRecovery = num(await strategy.pendingFee());
      const keptBefore = num(await strategy.investedUnderlyingBalance());
      const valueBefore = num(await strategy.currentBalance());
      await moveShares(sink, strategy.address, moved);
      const recoveredValue = num(await strategy.currentBalance()) - valueBefore;
      await strategy.doHardWork({ from: governance });
      const keptOnRecovery = num(await strategy.investedUnderlyingBalance()) - keptBefore;
      const feeAfterRecovery = num(await strategy.pendingFee());
      const carryAfter = num(await strategy.lossCarry());
      const wouldHaveBeen = (peak - dipped) * num(await strategy.totalFeeNumerator()) / num(await strategy.feeDenominator());
      console.log("  recovered: pendingFee", feeBeforeRecovery, "->", feeAfterRecovery,
                  "| lossCarry", carry, "->", carryAfter, "| a snapshot mark would have charged ~", Math.round(wouldHaveBeen));
      assert.isTrue(carryAfter < carry * 0.02, "the recovery must clear the carry");
      assert.isTrue(feeAfterRecovery - feeBeforeRecovery < wouldHaveBeen * 0.02,
        "no fee is due for a recovery back to the previous high water mark");
      // The mirror of the next test: depositors keep the whole recovery, not 1 - rate of it.
      console.log("  depositors kept", keptOnRecovery, "of a", Math.round(recoveredValue), "recovery =",
                  (keptOnRecovery / recoveredValue * 100).toFixed(2) + "%");
      assert.approximately(keptOnRecovery / recoveredValue, 1, 0.01,
        "depositors must keep the whole recovery");
    });

    it("charges again once the position is past its previous peak", async function () {
      assert.isTrue(num(await strategy.lossCarry()) < 1e3, "precondition: the carry must be spent");
      const rate = num(await strategy.totalFeeNumerator()) / num(await strategy.feeDenominator());

      const before = num(await strategy.investedUnderlyingBalance());
      const gain = Math.round(num(await strategy.currentBalance()) * 0.02);
      await fund(reference, "5000000000");
      await underlying.approve(FTOKEN, String(gain), { from: reference });
      await fToken.deposit(String(gain), strategy.address, { from: reference });
      await network.provider.send("evm_mine");
      await strategy.doHardWork({ from: governance });
      const kept = num(await strategy.investedUnderlyingBalance()) - before;

      console.log("  gain past the peak", gain, "| depositors kept", kept,
                  "=", (kept / gain * 100).toFixed(2) + "% (fee rate", (rate * 100).toFixed(0) + "%)");
      assert.equal(num(await strategy.lossCarry()), 0, "a gain must not create a carry");
      // Above the high water mark the fee is live again, so depositors keep 1 - rate of it.
      assert.approximately(kept / gain, 1 - rate, 0.01, "a new-high gain must be charged the fee");
    });
  });

  describe("Yield source deposit cap", function () {
    it("keeps working when the vault holds more than the PlasmaVault will accept", async function () {
      // Both IPOR Fusion vaults run a total deposit cap, and `deposit` reverts once it is
      // reached. Supplying blindly would take doHardWork() down with it and stop the
      // strategy earning on anything at all.
      await deploy();
      const headroom = num(await fToken.maxDeposit(strategy.address));
      const over = headroom + 500000000000; // headroom + 500,000 USDC
      await fund(farmer1, String(over));
      await depositVault(farmer1, underlying, vault, String(over));
      console.log("  headroom", headroom, "| vault holds", num(await vault.underlyingBalanceInVault()));

      await controller.doHardWork(vault.address, { from: governance });

      const supplied = num(await strategy.currentBalance());
      const idle = num(await strategy.investedUnderlyingBalance()) - supplied;
      console.log("  supplied", supplied, "| left idle in the strategy", idle);
      assert.isTrue(supplied > headroom * 0.99, "it must supply nearly all of what the cap allows");
      assert.isTrue(supplied <= headroom, "it must not exceed the cap");
      assert.isTrue(idle > 0, "the remainder must stay idle rather than reverting");

      // Nothing is lost: the vault still accounts for every unit, and holders can exit.
      const tvl = num(await vault.underlyingBalanceWithInvestment());
      assert.isTrue(tvl >= over * 0.999, "idle underlying must still count toward TVL");
      const before = num(await underlying.balanceOf(farmer1));
      await vault.withdraw((await vault.balanceOf(farmer1)).toString(), { from: farmer1 });
      assert.isTrue(num(await underlying.balanceOf(farmer1)) - before > 0, "holders must still be able to exit");
    });
  });

  describe("Exit fee attribution", function () {
    it("charges the PlasmaVault's exit fee to the withdrawing user only", async function () {
      await deploy();
      await fund(farmer1, "90000000000");
      await fund(farmer2, "10000000000");
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
      // (~0.02% here); the tolerance is an order of magnitude below that.
      assert.isTrue(bystander >= expected * (1 - 2e-5), "the exit fee leaked onto the remaining holders");
      // The withdrawer paid the fee, and nothing beyond the fee and IPOR's own revaluation.
      assert.isTrue(got <= entitlement * (1 - fee) * (1 + 1e-4), "the withdrawer did not pay the exit fee");
      assert.isTrue(got >= entitlement * (1 - fee) * ipor * (1 - 1e-4), "the withdrawer was charged more than the exit fee");
    });

    it("leaves the fee latent - and unpaid - for an exit served entirely from idle", async function () {
      // Deliberate policy, pinned here so a change to it is visible: the position is marked
      // GROSS, so the exit fee is charged only to the user whose withdrawal actually
      // triggers a redemption. A withdrawal the vault can serve out of idle underlying
      // triggers none, so that user pays nothing and the fee stays latent in the position
      // for whoever redeems next. Marking net (previewRedeem) would instead take the
      // haircut into the share price at investment time, charging every holder up front.
      await deploy();
      await fund(farmer1, "50000000000");
      await fund(farmer2, "50000000000");
      await depositVault(farmer1, underlying, vault, "50000000000");
      await controller.doHardWork(vault.address, { from: governance }); // farmer1 goes in
      await network.provider.send("evm_mine");
      await depositVault(farmer2, underlying, vault, "50000000000");    // farmer2 stays idle

      const idle = num(await vault.underlyingBalanceInVault());
      const entitlement1 = num(await vault.underlyingBalanceWithInvestmentForHolder(farmer1));
      assert.isTrue(entitlement1 <= idle, "precondition: the exit must be servable without redeeming");
      const heldShares = new BigNumber(await fTokenErc20.balanceOf(strategy.address)).toFixed();
      const latent = num(await fToken.convertToAssets(heldShares)) - num(await fToken.previewRedeem(heldShares));
      console.log("  vault idle", idle, "| farmer1 entitlement", entitlement1, "| latent fee in the position", latent);
      assert.isTrue(latent > 0, "precondition: the position must carry an exit fee");

      const before1 = num(await underlying.balanceOf(farmer1));
      await vault.withdraw((await vault.balanceOf(farmer1)).toString(), { from: farmer1 });
      const got1 = num(await underlying.balanceOf(farmer1)) - before1;
      console.log("  farmer1 received", got1, "of a", entitlement1, "entitlement - fee paid:", entitlement1 - got1);

      // No redemption, so no fee - the gross mark is what makes this true.
      assert.isTrue(got1 >= entitlement1 * (1 - 1e-6), "an exit needing no redemption must pay no exit fee");
      // The fee did not vanish: it is still sitting in the position farmer2 now owns, and
      // farmer2 pays it when they redeem.
      const before2 = num(await underlying.balanceOf(farmer2));
      const entitlement2 = num(await vault.underlyingBalanceWithInvestmentForHolder(farmer2));
      await vault.withdraw((await vault.balanceOf(farmer2)).toString(), { from: farmer2 });
      const got2 = num(await underlying.balanceOf(farmer2)) - before2;
      console.log("  farmer2 received", got2, "of a", entitlement2, "entitlement - fee paid:", entitlement2 - got2);
      assert.isTrue(entitlement2 - got2 >= latent * 0.99, "the deferred fee must land on the holder who does redeem");
    });

    it("still attributes it when the exit is served from vault idle plus a redeem", async function () {
      // The previous test exits a fully invested vault. Here 30% sits idle in the vault and
      // the exiter holds 50% of supply, so the payout is part idle and part fresh redemption
      // and the vault's min(entitlement, idle) has to bind on the entitlement for the fee to
      // stay with the withdrawer.
      await deploy();
      await vault.setVaultFractionToInvest(70, 100, { from: governance });
      await fund(farmer1, "50000000000");
      await fund(farmer2, "50000000000");
      await depositVault(farmer1, underlying, vault, "50000000000");
      await depositVault(farmer2, underlying, vault, "50000000000");
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");

      const idle = num(await vault.underlyingBalanceInVault());
      const entitlement = num(await vault.underlyingBalanceWithInvestmentForHolder(farmer2));
      assert.isTrue(entitlement > idle, "precondition: the exit must need a redemption too");
      console.log("  vault idle", idle, "| entitlement", entitlement);

      const fee = await iporExitFee();
      const probe = "1000000000000";
      const iporPps0 = num(await fToken.convertToAssets(probe));
      const pps0 = await pricePerShare();
      const before = num(await underlying.balanceOf(farmer2));
      await vault.withdraw((await vault.balanceOf(farmer2)).toString(), { from: farmer2 });
      const got = num(await underlying.balanceOf(farmer2)) - before;
      const ipor = num(await fToken.convertToAssets(probe)) / iporPps0;
      const bystander = (await pricePerShare()) / pps0;

      // Only the redeemed part carries a fee, so the exiter's shortfall is fee x (what was
      // redeemed), not fee x entitlement.
      const redeemed = entitlement - idle;
      console.log("  redeemed", redeemed, "| fee on it", Math.round(fee * redeemed), "| exiter paid", entitlement - got);
      console.log("  ipor pps ratio", ipor.toFixed(8), "bystander pps ratio", bystander.toFixed(8));

      const totalFee = num(await strategy.totalFeeNumerator()) / num(await strategy.feeDenominator());
      const expected = ipor > 1 ? 1 + (ipor - 1) * (1 - totalFee) : ipor;
      assert.isTrue(bystander >= expected * (1 - 2e-5), "the exit fee leaked onto the remaining holders");
      assert.isTrue(entitlement - got >= fee * redeemed * 0.99, "the withdrawer did not pay the fee on what was redeemed");
    });
  });
});
