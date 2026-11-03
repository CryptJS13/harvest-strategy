// HookVaultV2 must be a drop-in replacement for VaultV2. With both of its settings off
// (the default) it behaves identically to the stock implementation; and when the strategy
// does NOT implement IHardWorkHooks, compoundOnWithdraw falls back to IStrategy.doHardWork().
//
// Exercised against a live USDC vault whose strategy has no hooks.
//
// Developed and tested at blockNumber 25933440

const Utils = require("../utilities/Utils.js");
const { impersonates } = require("../utilities/hh-utils.js");

const addresses = require("../test-config.js");
const BigNumber = require("bignumber.js");
const { ethers, network } = require("hardhat");

const IERC20 = artifacts.require("IERC20");
const VaultV2 = artifacts.require("VaultV2");
const HookVaultV2 = artifacts.require("HookVaultV2");
const VaultProxy = artifacts.require("VaultProxy");
const IController = artifacts.require("IController");

const VAULT = "0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE"; // fUSDC
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_BALANCES_SLOT = 9;

describe("HookVaultV2 as a drop-in for VaultV2", function () {
  let accounts, governance, farmer;
  let usdc, stockVault, hookVault, strategy, controller;

  async function fund(who, amount) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [who, USDC_BALANCES_SLOT]));
    await network.provider.send("hardhat_setStorageAt", [USDC, key, ethers.utils.hexZeroPad(ethers.BigNumber.from(amount).toHexString(), 32)]);
  }

  async function depositAndWithdraw(vaultInstance, label) {
    const amount = "1000000000"; // 1,000 USDC
    const before = new BigNumber(await usdc.balanceOf(farmer));
    await vaultInstance.methods["deposit(uint256)"](amount, { from: farmer });
    const shares = (await vaultInstance.balanceOf(farmer)).toString();
    await vaultInstance.methods["withdraw(uint256)"](shares, { from: farmer });
    const after = new BigNumber(await usdc.balanceOf(farmer));
    const delta = after.minus(before);
    console.log(`  ${label}: shares minted ${shares}, USDC delta ${delta.toFixed()}`);
    return { shares, delta };
  }

  before(async function () {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();
    farmer = accounts[1];

    await impersonates([governance]);
    await web3.eth.sendTransaction({ from: accounts[9], to: governance, value: 10e18 });

    usdc = await IERC20.at(USDC);
    stockVault = await VaultV2.at(VAULT);
    controller = await IController.at(await stockVault.controller());
    strategy = await stockVault.strategy();

    await fund(farmer, "10000000000");
    await usdc.approve(VAULT, "10000000000", { from: farmer });
    console.log("Vault:", VAULT, "strategy:", strategy);
  });

  it("the strategy genuinely has no hooks", async function () {
    // Mirror HookVaultV2._supportsHardWorkHooks exactly: a proxy without the function
    // may return empty data instead of reverting, which must read as "not supported".
    let supported = false;
    try {
      const data = await ethers.provider.call({
        to: strategy,
        data: ethers.utils.id("supportsHardWorkHooks()").slice(0, 10),
      });
      supported = ethers.utils.hexDataLength(data) === 32 &&
        ethers.utils.defaultAbiCoder.decode(["bool"], data)[0];
    } catch (e) {
      supported = false;
    }
    console.log("  strategy advertises hooks:", supported);
    assert.isFalse(supported, "this test needs a strategy WITHOUT the hooks");
  });

  it("with everything off, produces the same result as stock VaultV2", async function () {
    // This file and hook-vault-deposit-cap.js target the same live proxy, and that one
    // upgrades it permanently. Run in one process (`npx hardhat test test/vault/`) mocha
    // loads them alphabetically, so without this check the comparison below would be
    // HookVaultV2 against HookVaultV2 and could no longer detect any divergence.
    const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    const currentImpl = ethers.utils.getAddress(
      "0x" + (await network.provider.send("eth_getStorageAt", [VAULT, implSlot, "latest"])).slice(-40)
    );
    assert.equal(
      currentImpl.toLowerCase(), addresses.VaultImplementationV2.toLowerCase(),
      "this comparison is only meaningful against the stock implementation - " +
      "run this file on its own, not in the same process as hook-vault-deposit-cap.js"
    );

    // The upgrade path burns 13 hours on the timelock, and the underlying protocol
    // accrues in that time. Give both runs the same elapsed time and the same transaction
    // count so the only difference measured is the vault implementation.
    const impl = await HookVaultV2.new({ from: governance });
    await stockVault.scheduleUpgrade(impl.address, { from: governance });

    const snapshot = await network.provider.send("evm_snapshot");
    await Utils.waitHours(13);
    await network.provider.send("evm_mine"); // stands in for the upgrade() transaction
    const stock = await depositAndWithdraw(stockVault, "stock VaultV2   ");
    await network.provider.send("evm_revert", [snapshot]);

    await Utils.waitHours(13);
    await (await VaultProxy.at(VAULT)).upgrade({ from: governance });
    hookVault = await HookVaultV2.at(VAULT);
    assert.isFalse(await hookVault.compoundOnWithdraw());
    assert.equal((await hookVault.depositCap()).toString(), "0");
    const hooked = await depositAndWithdraw(hookVault, "HookVaultV2     ");

    assert.equal(hooked.shares, stock.shares, "share mint must be identical");
    assert.equal(hooked.delta.toFixed(), stock.delta.toFixed(), "USDC returned must be identical");
  });

  it("with compoundOnWithdraw on, falls back to doHardWork() inside the withdrawal", async function () {
    // Idle underlying parked in the strategy is only deployed by a hard work, so whether
    // it is still there after the withdrawal shows whether one ran inside it. The
    // round-trip deposit is served from the vault's own balance either way, so nothing
    // else touches the strategy.
    const idle = "500000000"; // 500 USDC
    const donor = accounts[2];
    async function parkIdle() {
      await fund(donor, idle);
      await usdc.transfer(strategy, idle, { from: donor });
    }

    const snapshot = await network.provider.send("evm_snapshot");
    await parkIdle();
    const off = await depositAndWithdraw(hookVault, "compoundOnWithdraw off");
    const idleOff = new BigNumber(await usdc.balanceOf(strategy));
    await network.provider.send("evm_revert", [snapshot]);

    await hookVault.setCompoundOnWithdraw(true, { from: governance });
    await parkIdle();
    const on = await depositAndWithdraw(hookVault, "compoundOnWithdraw on ");
    const idleOn = new BigNumber(await usdc.balanceOf(strategy));
    console.log("  idle left in the strategy: off", idleOff.toFixed(), "/ on", idleOn.toFixed());

    assert.equal(on.shares, off.shares, "the deposit path is untouched by the flag");
    Utils.assertBNGte(on.delta, off.delta);
    assert.equal(idleOff.toFixed(), idle, "no hard work must run with the flag off");
    assert.isTrue(idleOn.lt(new BigNumber(idle).idiv(100)), "the fallback doHardWork() must have deployed the idle balance");
  });

  it("still lets the keeper harvest through HookVaultV2", async function () {
    const ppsBefore = new BigNumber(await hookVault.getPricePerFullShare());
    await Utils.advanceNBlock(100);
    await controller.doHardWork(VAULT, { from: governance });
    const ppsAfter = new BigNumber(await hookVault.getPricePerFullShare());
    console.log("  pps", ppsBefore.toFixed(), "->", ppsAfter.toFixed());
    assert.isTrue(ppsAfter.gte(ppsBefore), "share price must not fall across a harvest");
  });
});
