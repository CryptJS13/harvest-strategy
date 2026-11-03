// The governance deposit cap on HookVaultV2. Off by default (cap 0 = uncapped), enforced
// before any funds move, and reflected in the ERC-4626 maxDeposit/maxMint views so an
// integrator sizing a deposit is told the real limit instead of type(uint256).max.
//
// Exercised against a live USDC vault so the cap is measured against real TVL.
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

const VAULT = "0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE"; // fUSDC
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_BALANCES_SLOT = 9;
const MAX_UINT = new BigNumber(2).pow(256).minus(1);

describe("HookVaultV2 deposit cap", function () {
  let governance, farmer, usdc, vault;

  async function fund(who, amount) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [who, USDC_BALANCES_SLOT]));
    await network.provider.send("hardhat_setStorageAt", [USDC, key, ethers.utils.hexZeroPad(ethers.BigNumber.from(amount).toHexString(), 32)]);
  }

  async function revertsWith(fn, fragment) {
    let msg = "";
    try { await fn(); } catch (e) { msg = e.message || ""; }
    assert.include(msg, fragment, `expected a revert containing "${fragment}"`);
    return msg;
  }

  before(async function () {
    governance = addresses.Governance;
    const accounts = await web3.eth.getAccounts();
    farmer = accounts[1];

    await impersonates([governance]);
    await web3.eth.sendTransaction({ from: accounts[9], to: governance, value: 10e18 });

    usdc = await IERC20.at(USDC);
    await fund(farmer, "30000000000");
    await usdc.approve(VAULT, "30000000000", { from: farmer });

    const stock = await VaultV2.at(VAULT);
    const impl = await HookVaultV2.new({ from: governance });
    await stock.scheduleUpgrade(impl.address, { from: governance });
    await Utils.waitHours(13);
    await (await VaultProxy.at(VAULT)).upgrade({ from: governance });
    vault = await HookVaultV2.at(VAULT);
  });

  it("defaults to uncapped, and the ERC-4626 views say so", async function () {
    assert.equal((await vault.depositCap()).toString(), "0", "cap must default to 0");
    assert.equal((await vault.maxDeposit(farmer)).toString(), MAX_UINT.toFixed());
    assert.equal((await vault.maxMint(farmer)).toString(), MAX_UINT.toFixed());
  });

  it("only governance can set the cap", async function () {
    await revertsWith(() => vault.setDepositCap("1", { from: farmer }), "Not governance");
    assert.equal((await vault.depositCap()).toString(), "0", "cap must be unchanged");
  });

  it("accepts deposits up to the cap and rejects the one that would cross it", async function () {
    const tvl = new BigNumber(await vault.underlyingBalanceWithInvestment());
    const cap = tvl.plus("1000000000"); // 1,000 USDC of headroom
    await vault.setDepositCap(cap.toFixed(), { from: governance });
    console.log("  TVL", tvl.toFixed(), "cap", cap.toFixed());

    const room = new BigNumber(await vault.maxDeposit(farmer));
    console.log("  maxDeposit reports", room.toFixed());
    assert.isTrue(room.lte("1000000000") && room.gt("990000000"), "maxDeposit should report the real headroom");

    // maxMint must agree with maxDeposit.
    const mintable = new BigNumber(await vault.maxMint(farmer));
    const expected = new BigNumber(await vault.convertToShares(room.toFixed()));
    assert.equal(mintable.toFixed(), expected.toFixed(), "maxMint must equal convertToShares(maxDeposit)");

    await vault.methods["deposit(uint256)"]("900000000", { from: farmer }); // inside the cap
    await revertsWith(
      () => vault.methods["deposit(uint256)"]("500000000", { from: farmer }), // would cross it
      "Deposit cap reached"
    );
    console.log("  over-cap deposit correctly rejected");
  });

  it("blocks deposits but never traps funds when the cap is below TVL", async function () {
    await vault.setDepositCap("1", { from: governance });
    assert.equal((await vault.maxDeposit(farmer)).toString(), "0", "no headroom left");
    assert.equal((await vault.maxMint(farmer)).toString(), "0");
    await revertsWith(() => vault.methods["deposit(uint256)"]("1000000", { from: farmer }), "Deposit cap reached");

    // Existing holders must still be able to leave.
    const shares = (await vault.balanceOf(farmer)).toString();
    const before = new BigNumber(await usdc.balanceOf(farmer));
    await vault.methods["withdraw(uint256)"](shares, { from: farmer });
    const after = new BigNumber(await usdc.balanceOf(farmer));
    console.log("  withdrawal under a binding cap returned", after.minus(before).toFixed());
    Utils.assertBNGt(after, before);
  });

  it("clearing the cap restores uncapped behaviour", async function () {
    await vault.setDepositCap(0, { from: governance });
    assert.equal((await vault.depositCap()).toString(), "0");
    assert.equal((await vault.maxDeposit(farmer)).toString(), MAX_UINT.toFixed());
    await vault.methods["deposit(uint256)"]("5000000000", { from: farmer });
    Utils.assertBNGt(new BigNumber(await vault.balanceOf(farmer)), new BigNumber(0));
    console.log("  large deposit accepted after clearing the cap");
  });
});
