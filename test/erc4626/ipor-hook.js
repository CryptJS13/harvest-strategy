// compoundOnWithdraw on an IPOR PlasmaVault, through HookVaultV2 + IHardWorkHooks.
//
// IPOR locks the depositing account against redemption until block.timestamp + 1, i.e.
// for the rest of the block. A plain doHardWork() ends by depositing into the PlasmaVault,
// so running it inside a withdrawal that then redeems from the same PlasmaVault reverts
// with AccountIsLocked(uint256). The strategy's doHardWorkOnWithdraw() credits the exiting
// user the same accrued interest without the deposit, and HookVaultV2 uses it.
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
const LOCKED = "a592703b"; // AccountIsLocked(uint256)

describe("Mainnet IPOR Lending bdUSD - compoundOnWithdraw", function () {
  let accounts, governance, farmer1, farmer2, donor;
  let underlying, fToken;
  let controller, vault, strategy;

  async function fund(who, amount) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [who, USDC_BALANCES_SLOT]));
    await network.provider.send("hardhat_setStorageAt", [USDC, key, ethers.utils.hexZeroPad(ethers.BigNumber.from(amount).toHexString(), 32)]);
  }

  // Grows the strategy's PlasmaVault position without touching storedBalance - what
  // accrued-but-unharvested interest looks like. The PlasmaVault caches its market
  // balances, so advancing time does not move convertToAssets on a fork; depositing on the
  // strategy's behalf produces the same stale-storedBalance state deterministically.
  async function accrueInterest(amount) {
    await underlying.approve(FTOKEN, amount, { from: donor });
    await fToken.deposit(amount, strategy.address, { from: donor });
    await network.provider.send("evm_mine"); // clear the lock the donation armed
  }

  async function revertDataOf(txHash) {
    const tr = await network.provider.send("debug_traceTransaction", [txHash]);
    return (tr.returnValue || "").replace(/^0x/, "");
  }

  before(async function () {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();
    farmer1 = accounts[1];
    farmer2 = accounts[2];
    donor = accounts[3];

    await impersonates([governance]);
    await web3.eth.sendTransaction({ from: accounts[9], to: governance, value: 10e18 });

    underlying = await IERC20.at(USDC);
    fToken = await IERC4626.at(FTOKEN);

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

    await fund(farmer1, "90000000000"); // 90,000 USDC
    await fund(farmer2, "10000000000"); // 10,000 USDC
    await fund(donor, "10000000000");

    await depositVault(farmer1, underlying, vault, "90000000000");
    await depositVault(farmer2, underlying, vault, "10000000000");
    await controller.doHardWork(vault.address, { from: governance });
    await network.provider.send("evm_mine");
  });

  it("is off by default, and only governance can turn it on", async function () {
    assert.isFalse(await vault.compoundOnWithdraw());
    let msg = "";
    try { await vault.setCompoundOnWithdraw(true, { from: farmer1 }); } catch (e) { msg = e.message || ""; }
    assert.include(msg, "Not governance");
    assert.isTrue(await strategy.supportsHardWorkHooks());
  });

  it("control: a hard work and a redemption in the same block hit the redemption lock", async function () {
    // Idle underlying in the vault, so the hard work has something to deposit.
    await fund(farmer1, "1000000000");
    await depositVault(farmer1, underlying, vault, "1000000000");

    const shares = (await vault.balanceOf(farmer2)).toString();
    const ctrl = await ethers.getContractAt(["function doHardWork(address)"], controller.address, await ethers.getSigner(governance));
    const v = await ethers.getContractAt(["function withdraw(uint256) returns (uint256)"], vault.address, await ethers.getSigner(farmer2));

    await network.provider.send("evm_setAutomine", [false]);
    const hardWork = await ctrl.doHardWork(vault.address, { gasLimit: 6000000 });
    const withdrawal = await v["withdraw(uint256)"](shares, { gasLimit: 6000000 });
    await network.provider.send("evm_mine");
    await network.provider.send("evm_setAutomine", [true]);

    const r1 = await ethers.provider.getTransactionReceipt(hardWork.hash);
    const r2 = await ethers.provider.getTransactionReceipt(withdrawal.hash);
    assert.equal(r1.blockNumber, r2.blockNumber, "both must land in one block");
    assert.equal(r1.status, 1, "the hard work itself must succeed");
    assert.equal(r2.status, 0, "precondition: the same-block redemption must be refused");
    const data = await revertDataOf(withdrawal.hash);
    console.log("  same-block withdrawal reverted with", "0x" + data.slice(0, 8));
    assert.include(data, LOCKED, "should revert with AccountIsLocked");
    assert.equal((await vault.balanceOf(farmer2)).toString(), shares, "the failed withdrawal must not have burned anything");
    await network.provider.send("evm_mine");
  });

  it("credits the withdrawing user the interest accrued since the last hard work", async function () {
    await accrueInterest("5000000000"); // +5,000 USDC on the strategy's position

    const stored = new BigNumber(await strategy.storedBalance());
    const current = new BigNumber(await strategy.currentBalance());
    console.log("  stored ", stored.toFixed());
    console.log("  current", current.toFixed(), "(gap", current.minus(stored).toFixed() + ")");
    assert.isTrue(current.gt(stored), "precondition: interest must have accrued");

    // Price farmer2's partial exit with the flag off vs on, from the same state.
    const shares = (await vault.balanceOf(farmer2)).toString();
    const snapshot = await network.provider.send("evm_snapshot");
    const b0 = new BigNumber(await underlying.balanceOf(farmer2));
    await vault.withdraw(shares, { from: farmer2 });
    const withoutCompound = new BigNumber(await underlying.balanceOf(farmer2)).minus(b0);
    await network.provider.send("evm_revert", [snapshot]);

    await vault.setCompoundOnWithdraw(true, { from: governance });
    const b1 = new BigNumber(await underlying.balanceOf(farmer2));
    await vault.withdraw(shares, { from: farmer2 });
    const withCompound = new BigNumber(await underlying.balanceOf(farmer2)).minus(b1);

    console.log("  received without compoundOnWithdraw:", withoutCompound.toFixed());
    console.log("  received with    compoundOnWithdraw:", withCompound.toFixed());
    Utils.assertBNGt(withCompound, withoutCompound);
    assert.equal((await vault.balanceOf(farmer2)).toString(), "0");
  });

  it("does not deposit into the PlasmaVault on the withdrawal path", async function () {
    assert.isTrue(await vault.compoundOnWithdraw());
    // Everything invested, then idle underlying in the strategy: a full doHardWork() would
    // deposit it, arm the lock, and the redemption a few lines later would revert (the
    // control above). The hook leaves it idle, and the redemption goes through.
    await fund(farmer2, "10000000000");
    await depositVault(farmer2, underlying, vault, "10000000000");
    await controller.doHardWork(vault.address, { from: governance });
    await underlying.transfer(strategy.address, "1000000000", { from: donor });
    await network.provider.send("evm_mine");
    assert.equal((await vault.underlyingBalanceInVault()).toString(), "0", "precondition: the exit must redeem from the PlasmaVault");

    const positionBefore = new BigNumber(await strategy.currentBalance());
    const shares = (await vault.balanceOf(farmer2)).toString();
    await vault.withdraw(shares, { from: farmer2 });
    const positionAfter = new BigNumber(await strategy.currentBalance());

    console.log("  PlasmaVault position", positionBefore.toFixed(), "->", positionAfter.toFixed());
    Utils.assertBNGt(positionBefore, positionAfter);
    assert.equal((await vault.balanceOf(farmer2)).toString(), "0");
  });

  it("keeps doHardWork() deploying capital, so the keeper is unaffected", async function () {
    await underlying.transfer(strategy.address, "1000000000", { from: donor });
    const idleBefore = new BigNumber(await underlying.balanceOf(strategy.address));
    const suppliedBefore = new BigNumber(await strategy.currentBalance());
    assert.isTrue(idleBefore.gt(0));

    await controller.doHardWork(vault.address, { from: governance });

    const idleAfter = new BigNumber(await underlying.balanceOf(strategy.address));
    const suppliedAfter = new BigNumber(await strategy.currentBalance());
    console.log("  idle    ", idleBefore.toFixed(), "->", idleAfter.toFixed());
    console.log("  supplied", suppliedBefore.toFixed(), "->", suppliedAfter.toFixed());
    Utils.assertBNGt(suppliedAfter, suppliedBefore);
    assert.isTrue(idleAfter.lt(idleBefore), "keeper harvest should deploy the idle balance");
  });
});
