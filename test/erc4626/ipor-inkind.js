// In-kind redemption for the two mainnet IPOR Fusion vaults.
//
// While enabled, a holder burns vault shares and receives their pro-rata slice of the
// PlasmaVault's own shares instead of the underlying - an exit that does not depend on how
// much the PlasmaVault can redeem instantly. The switch is off by default and the normal
// withdrawal path keeps working throughout.
//
// Developed and tested at blockNumber 25933440

const Utils = require("../utilities/Utils.js");
const { impersonates, setupCoreProtocol, depositVault } = require("../utilities/hh-utils.js");

const addresses = require("../test-config.js");
const BigNumber = require("bignumber.js");
const { ethers, network } = require("hardhat");

const IERC20 = artifacts.require("IERC20");
const IERC4626 = artifacts.require("contracts/base/interface/IERC4626.sol:IERC4626");
const VaultV2InKind = artifacts.require("VaultV2InKind");

const FLEET = [
  { name: "bdUSD", artifact: "IPORLendingStrategyMainnet_bdUSD", token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", slot: 9,
    plasmaVault: "0xF8F226dA66244F89e70C5B5D1a5C5b0d505Eb1d8", amount: "50000000000" },   // 50,000 USDC
  { name: "BTCdc", artifact: "IPORLendingStrategyMainnet_BTCdc", token: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", slot: 0,
    plasmaVault: "0x7659fc26bf3A63E8133BbECB7E16ACD48EE8E292", amount: "50000000" },        // 0.5 WBTC
];

const num = (x) => Number(new BigNumber(x).toFixed());

describe("Mainnet IPOR Fusion - in-kind redemption", function () {
  let accounts, governance, farmer1, farmer2;

  before(async function () {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();
    farmer1 = accounts[1];
    farmer2 = accounts[2];
    await impersonates([governance]);
    await web3.eth.sendTransaction({ from: accounts[9], to: governance, value: 10e18 });
  });

  async function fund(spec, who, amount) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [who, spec.slot]));
    await network.provider.send("hardhat_setStorageAt", [spec.token, key,
      ethers.utils.hexZeroPad(ethers.BigNumber.from(amount).toHexString(), 32)]);
  }

  async function deploy(spec, farmers = [farmer1]) {
    const underlying = await IERC20.at(spec.token);
    const impl = await VaultV2InKind.new({ from: governance });
    const [controller, v, strategy] = await setupCoreProtocol({
      existingVaultAddress: null,
      vaultImplementationOverride: impl.address,
      strategyArtifact: artifacts.require(spec.artifact),
      strategyArtifactIsUpgradable: true,
      underlying, governance,
    });
    const vault = await VaultV2InKind.at(v.address);
    for (const f of farmers) await fund(spec, f, spec.amount);
    return { underlying, vault, strategy, controller, pv: await IERC20.at(spec.plasmaVault) };
  }

  describe("Drop-in behaviour with the switch off", function () {
    it("defaults to off, refuses in-kind, and round-trips normally", async function () {
      const spec = FLEET[0];
      const { underlying, vault, controller } = await deploy(spec);
      assert.isFalse(await vault.redeemInKindEnabled(), "must default to off");

      let msg = "";
      try { await vault.redeemInKind(1, farmer1, farmer1, { from: farmer1 }); } catch (e) { msg = e.message || ""; }
      assert.include(msg, "In-kind redemptions not enabled");

      const before = num(await underlying.balanceOf(farmer1));
      await depositVault(farmer1, underlying, vault, spec.amount);
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine"); // clear the redemption lock the deposit armed
      await vault.withdraw((await vault.balanceOf(farmer1)).toString(), { from: farmer1 });
      const after = num(await underlying.balanceOf(farmer1));
      console.log("  round trip with the switch off:", before, "->", after);
      assert.isTrue(after >= before * 0.99, "a normal round trip must still work");
    });

    it("only governance can flip the switch", async function () {
      const { vault } = await deploy(FLEET[0]);
      let msg = "";
      try { await vault.setRedeemInKindEnabled(true, { from: farmer1 }); } catch (e) { msg = e.message || ""; }
      assert.include(msg, "Not governance");
      assert.isFalse(await vault.redeemInKindEnabled());
    });
  });

  describe("In-kind payout", function () {
    it("pays the exact pro-rata slice of PlasmaVault shares, and preview tracks it", async function () {
      const spec = FLEET[0];
      const { underlying, vault, strategy, controller, pv } = await deploy(spec);
      await depositVault(farmer1, underlying, vault, spec.amount);
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");
      await vault.setRedeemInKindEnabled(true, { from: governance });
      assert.equal(await vault.inKindToken(), pv.address, "inKindToken must be the PlasmaVault");

      const shares = new BigNumber(await vault.balanceOf(farmer1));
      const half = shares.idiv(2).toFixed();
      const supply = num(await vault.totalSupply());
      const stratShares = num(await pv.balanceOf(strategy.address));
      const fToken = await IERC4626.at(pv.address);

      const [, previewPool] = Object.values(await vault.previewRedeemInKind(half));
      const before = num(await pv.balanceOf(farmer2));
      await vault.redeemInKind(half, farmer2, farmer1, { from: farmer1 });
      const got = num(await pv.balanceOf(farmer2)) - before;

      const feeShares = num(await fToken.previewWithdraw((await strategy.pendingFee()).toString()));
      const expected = Math.floor((stratShares - feeShares) * num(half) / supply);
      console.log("  strategy held", stratShares, "shares; fee carve-out", feeShares);
      console.log("  preview", num(previewPool), "| actual", got, "| expected", expected);
      assert.isTrue(got > 0, "must pay out something");
      assert.approximately(got / expected, 1, 1e-9, "payout must be the pro-rata slice net of fee shares");
      assert.approximately(got / num(previewPool), 1, 1e-7, "preview must track execution");
      assert.isTrue(got <= num(previewPool), "preview must never understate the fee taken");

      assert.equal((await vault.balanceOf(farmer1)).toString(), shares.minus(half).toFixed());
      await vault.withdraw((await vault.balanceOf(farmer1)).toString(), { from: farmer1 });
      assert.equal((await vault.balanceOf(farmer1)).toString(), "0");
    });

    it("does not move the share price for the holders who stay", async function () {
      const spec = FLEET[0];
      const { underlying, vault, controller } = await deploy(spec, [farmer1, farmer2]);
      await depositVault(farmer1, underlying, vault, spec.amount);
      await depositVault(farmer2, underlying, vault, spec.amount);
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");
      await vault.setRedeemInKindEnabled(true, { from: governance });

      const ppsBefore = num(await vault.getPricePerFullShare());
      const entBefore = num(await vault.underlyingBalanceWithInvestmentForHolder(farmer2));
      await vault.redeemInKind((await vault.balanceOf(farmer1)).toString(), farmer1, farmer1, { from: farmer1 });
      const ppsAfter = num(await vault.getPricePerFullShare());
      const entAfter = num(await vault.underlyingBalanceWithInvestmentForHolder(farmer2));

      console.log("  bystander pps", ppsBefore, "->", ppsAfter, "| entitlement", entBefore, "->", entAfter);
      assert.approximately(ppsAfter / ppsBefore, 1, 2e-4, "an in-kind exit must not reprice the remaining holders");
      assert.approximately(entAfter / entBefore, 1, 2e-4, "the bystander keeps their entitlement");
    });

    it("keeps the fee carve-out honest when a loss is still being carried", async function () {
      const spec = FLEET[0];
      const { underlying, vault, strategy, controller, pv } = await deploy(spec);
      await depositVault(farmer1, underlying, vault, spec.amount);
      await controller.doHardWork(vault.address, { from: governance });
      await network.provider.send("evm_mine");
      await vault.setRedeemInKindEnabled(true, { from: governance });

      // A NAV dip then a recovery: PlasmaVault shares out of the strategy and back.
      const held = new BigNumber(await pv.balanceOf(strategy.address));
      const moved = held.idiv(20).toFixed();
      await impersonates([strategy.address]);
      await web3.eth.sendTransaction({ from: accounts[9], to: strategy.address, value: 1e18 });
      await pv.transfer(accounts[7], moved, { from: strategy.address });
      await network.provider.send("evm_mine");
      await strategy.doHardWork({ from: governance });
      const carry = num(await strategy.lossCarry());
      console.log("  lossCarry after the dip:", carry);
      assert.isTrue(carry > 0, "precondition: a loss must be carried");

      await pv.transfer(strategy.address, moved, { from: accounts[7] });
      await network.provider.send("evm_mine");
      const shares = (await vault.balanceOf(farmer1)).toString();
      const [, preview] = Object.values(await vault.previewRedeemInKind(shares));
      const heldNow = num(await pv.balanceOf(strategy.address));

      const before = num(await pv.balanceOf(farmer2));
      await vault.redeemInKind(shares, farmer2, farmer1, { from: farmer1 });
      const got = num(await pv.balanceOf(farmer2)) - before;
      console.log("  paid out", got, "of", heldNow, "held =", (got / heldNow * 100).toFixed(2) + "%");
      assert.approximately(got / num(preview), 1, 1e-7, "preview must still track execution while carrying a loss");
      assert.isTrue(got > heldNow * 0.99, "the carry must not inflate the fee carve-out");
    });
  });

  describe("Both vaults", function () {
    for (const spec of FLEET) {
      it(`${spec.name}: in-kind round trip`, async function () {
        const { underlying, vault, controller, pv } = await deploy(spec);
        await depositVault(farmer1, underlying, vault, spec.amount);
        await controller.doHardWork(vault.address, { from: governance });
        await network.provider.send("evm_mine");
        await vault.setRedeemInKindEnabled(true, { from: governance });

        const shares = (await vault.balanceOf(farmer1)).toString();
        const [, previewPool] = Object.values(await vault.previewRedeemInKind(shares));
        const before = num(await pv.balanceOf(farmer1));
        await vault.redeemInKind(shares, farmer1, farmer1, { from: farmer1 });
        const got = num(await pv.balanceOf(farmer1)) - before;
        console.log(`  ${spec.name}: received ${got} PlasmaVault shares (preview ${num(previewPool)})`);
        assert.approximately(got / num(previewPool), 1, 1e-7);
        assert.isTrue(got > 0);
        assert.equal((await vault.balanceOf(farmer1)).toString(), "0");
      });
    }
  });
});
