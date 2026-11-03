// Sunset of the live Apostro Resolv USDC strategy (MorphoVaultStrategyV2Mainnet_AR_USDC).
//
// The Apostro Resolv USDC Morpho vault no longer lets the strategy withdraw (maxWithdraw is 0,
// every redemption reverts with NotEnoughLiquidity), so the V2 strategy's doHardWork and any
// withdrawal above its idle balance revert. The funds stuck there were compensated in USDC,
// claimed through Merkl straight into the strategy on 2026-10-09. This test upgrades the live
// proxy in place to the sunset implementation and checks that the Morpho position is ignored
// completely, the rewards get sold for USDC, and the holders can take their USDC out.
//
// Developed and tested at blockNumber 26333000

const Utils = require("../utilities/Utils.js");
const { impersonates } = require("../utilities/hh-utils.js");
const { expectRevert } = require("@openzeppelin/test-helpers");

const addresses = require("../test-config.js");
const BigNumber = require("bignumber.js");
const IERC20 = artifacts.require("IERC20");
const Vault = artifacts.require("VaultV2");
const IController = artifacts.require("IController");
const IUpgradeableStrategy = artifacts.require("IUpgradeableStrategy");
const StrategyProxy = artifacts.require("StrategyProxy");
const OldStrategy = artifacts.require("MorphoVaultStrategyV2Mainnet_AR_USDC");
const Strategy = artifacts.require("MorphoVaultSunsetStrategyMainnet_AR_USDC");

const VAULT = "0xa8be729C0b2ce16C12f223BDE20B2fD715dae37F";
const STRATEGY = "0x9867C2383dD0747a5a92F8Fdc2f3c95649D92153";
const MORPHO_VAULT = "0x214B47C50057eFaa7adc1B1C2608C3751Cd77D78";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const MORPHO = "0x58D97B57BB95320F9a05dC918Aef65434969c2B2";
const FXN = "0x365AccFCa291e7D3914637ABf1F7635dB165Bb09";

// the two holders of the vault at the fork block
const AUTOPILOT = "0x3151cEE0cdb517C0E7Db2B55FF5085e7D1809d90"; // IPOR "Autopilot USDC Ethereum"
const HARD_WORKER = "0x6a74649aCFD7822ae8Fb78463a9f2192752E5Aa2";

const usdcWhale = "0x072a452Eb96f4CD3458473754d23B86eEe4E8bDf";
const morphoWhale = "0x72b23AeBbD4aBfc1cEA755686710E74c93696Fae";
const fxnWhale = "0xc2979a224d9555F56b802c03F38232c7627d8bb7";

const STORED_SUPPLIED_SLOT = "0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2";
const PENDING_FEE_SLOT = "0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97";

const WRITTEN_OFF_TOPIC = web3.utils.keccak256("MorphoPositionWrittenOff(address,uint256,uint256)");
const SKIPPED_TOPIC = web3.utils.keccak256("RewardLiquidationSkipped()");
const SALE_SKIPPED_TOPIC = web3.utils.keccak256("RewardSaleSkipped(address)");

describe("Mainnet Morpho Apostro Resolv USDC - sunset upgrade", function() {
  let accounts, governance, farmer1;
  let usdc, weth, farm, morphoToken, fxnToken, morphoShares;
  let controller, vault, strategy, impl;
  let snapshotId;

  // state of the live strategy before the upgrade
  let live = {};

  async function balances() {
    return {
      usdc: new BigNumber(await usdc.balanceOf(STRATEGY)),
      morpho: new BigNumber(await morphoToken.balanceOf(STRATEGY)),
      fxn: new BigNumber(await fxnToken.balanceOf(STRATEGY)),
      weth: new BigNumber(await weth.balanceOf(STRATEGY)),
      shares: new BigNumber(await morphoShares.balanceOf(STRATEGY)),
      invested: new BigNumber(await strategy.investedUnderlyingBalance()),
      inVault: new BigNumber(await vault.underlyingBalanceInVault()),
      total: new BigNumber(await vault.underlyingBalanceWithInvestment()),
      supply: new BigNumber(await vault.totalSupply()),
      pps: new BigNumber(await vault.getPricePerFullShare()),
    };
  }

  function hasLog(receipt, topic, indexedAddress) {
    return receipt.rawLogs.some(l => l.topics[0] == topic
      && (!indexedAddress || web3.eth.abi.decodeParameter("address", l.topics[1]) == indexedAddress));
  }

  before(async function() {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();
    farmer1 = accounts[1];

    await impersonates([governance, AUTOPILOT, HARD_WORKER, usdcWhale, morphoWhale, fxnWhale]);
    // the Autopilot PlasmaVault has no payable fallback, so gas money is set rather than sent
    for (const a of [governance, AUTOPILOT, HARD_WORKER, usdcWhale, morphoWhale, fxnWhale]) {
      await hre.network.provider.send("hardhat_setBalance", [a, web3.utils.toHex(new BigNumber(10e18).toFixed())]);
    }

    usdc = await IERC20.at(USDC);
    weth = await IERC20.at(WETH);
    farm = await IERC20.at(addresses.FARM);
    morphoToken = await IERC20.at(MORPHO);
    fxnToken = await IERC20.at(FXN);
    morphoShares = await IERC20.at(MORPHO_VAULT);
    controller = await IController.at(addresses.Controller);
    vault = await Vault.at(VAULT);
    assert.equal(await vault.strategy(), STRATEGY, "the live vault should still run the strategy under test");

    // the farmer gets some USDC to deposit later
    await usdc.transfer(farmer1, new BigNumber(10000e6).toFixed(), { from: usdcWhale });

    // ---- the live strategy, as it is now ----
    const old = await OldStrategy.at(STRATEGY);
    live.storedSupplied = new BigNumber(await old.storedSupplied());
    live.pendingFee = new BigNumber(await old.pendingFee());
    live.currentSupplied = new BigNumber(await old.currentSupplied());
    live.usdc = new BigNumber(await usdc.balanceOf(STRATEGY));
    live.shares = new BigNumber(await morphoShares.balanceOf(STRATEGY));
    live.invested = new BigNumber(await old.investedUnderlyingBalance());
    live.pps = new BigNumber(await vault.getPricePerFullShare());
    live.supply = new BigNumber(await vault.totalSupply());
    live.rewardTokens = [await old.rewardTokens(0), await old.rewardTokens(1)];
    console.log("before the upgrade:");
    console.log("  USDC in the strategy:        ", live.usdc.toFixed());
    console.log("  Morpho vault shares:         ", live.shares.toFixed());
    console.log("  storedSupplied:              ", live.storedSupplied.toFixed());
    console.log("  pendingFee:                  ", live.pendingFee.toFixed());
    console.log("  Morpho vault says (locked):  ", live.currentSupplied.toFixed());
    console.log("  investedUnderlyingBalance:   ", live.invested.toFixed());
    console.log("  vault share price:           ", live.pps.toFixed());
    Utils.assertBNGt(live.usdc, 0);
    Utils.assertBNGt(live.storedSupplied, 0);
    // the V2 accounting counts the stuck position on top of the USDC that compensated it
    Utils.assertBNEq(live.invested, live.usdc.plus(live.storedSupplied).minus(live.pendingFee));

    // the strategy is broken: hard work reverts, and so does every withdrawal, however small
    // (the live V2 bytecode accrues a fee on the inflated Morpho balance and then underflows)
    await expectRevert.unspecified(controller.doHardWork(VAULT, { from: governance }));
    await expectRevert.unspecified(vault.withdraw(new BigNumber(1e6).toFixed(), { from: HARD_WORKER }));
    await expectRevert.unspecified(vault.withdraw(new BigNumber(await vault.balanceOf(AUTOPILOT)).toFixed(), { from: AUTOPILOT }));

    // ---- the upgrade, as governance would do it ----
    impl = await Strategy.new();
    const upgradable = await IUpgradeableStrategy.at(STRATEGY);
    await upgradable.scheduleUpgrade(impl.address, { from: governance });
    console.log("Upgrade scheduled. Waiting...");
    await Utils.waitHours(13);
    const upgradeTx = await upgradable.upgrade({ from: governance });
    live.upgradeReceipt = upgradeTx.receipt;
    strategy = await Strategy.at(STRATEGY);
    console.log("Strategy upgraded in place to ", impl.address);
  });

  beforeEach(async function() {
    snapshotId = await hre.network.provider.send("evm_snapshot");
  });

  afterEach(async function() {
    await hre.network.provider.send("evm_revert", [snapshotId]);
  });

  describe("The upgrade", function() {
    it("switches the proxy in place and keeps its state", async function() {
      const proxy = await StrategyProxy.at(STRATEGY);
      assert.equal(await proxy.implementation(), impl.address);
      assert.equal(await strategy.nextImplementation(), "0x0000000000000000000000000000000000000000");
      Utils.assertBNEq(await strategy.nextImplementationTimestamp(), 0);

      assert.equal(await strategy.vault(), VAULT);
      assert.equal(await strategy.underlying(), USDC);
      assert.equal(await strategy.morphoVault(), MORPHO_VAULT);
      assert.equal(await strategy.rewardPool(), MORPHO_VAULT);
      assert.equal(await strategy.rewardToken(), WETH);
      assert.equal(await strategy.morphoPrePay(), addresses.RewardPrePayMorpho);
      assert.equal(await strategy.strategist(), addresses.CommunityMsig);
      assert.equal(await strategy.governance(), governance);
      assert.equal(await strategy.controller(), addresses.Controller);
      assert.equal(await strategy.rewardTokens(0), live.rewardTokens[0]);
      assert.equal(await strategy.rewardTokens(1), live.rewardTokens[1]);
      assert.equal(await strategy.rewardTokens(0), MORPHO);
      assert.equal(await strategy.rewardTokens(1), FXN);
      await expectRevert.unspecified(strategy.rewardTokens(2));
      assert.equal(await strategy.sell(), true);
      assert.equal(await strategy.pausedInvesting(), false);
    });

    it("writes the locked Morpho position off", async function() {
      assert.equal(hasLog(live.upgradeReceipt, WRITTEN_OFF_TOPIC), true, "MorphoPositionWrittenOff should be emitted");
      const log = live.upgradeReceipt.rawLogs.find(l => l.topics[0] == WRITTEN_OFF_TOPIC);
      assert.equal(log.address.toLowerCase(), STRATEGY.toLowerCase());
      assert.equal(web3.eth.abi.decodeParameter("address", log.topics[1]), MORPHO_VAULT);
      const decoded = web3.eth.abi.decodeParameters(["uint256", "uint256"], log.data);
      Utils.assertBNEq(decoded[0], live.storedSupplied);
      Utils.assertBNEq(decoded[1], live.pendingFee);

      Utils.assertBNEq(await web3.eth.getStorageAt(STRATEGY, STORED_SUPPLIED_SLOT), 0);
      Utils.assertBNEq(await web3.eth.getStorageAt(STRATEGY, PENDING_FEE_SLOT), 0);

      const b = await balances();
      // the shares are still there, just not counted
      Utils.assertBNEq(b.shares, live.shares);
      Utils.assertBNEq(b.usdc, live.usdc);
      Utils.assertBNEq(b.invested, live.usdc);
      Utils.assertBNEq(b.inVault, 0);
      Utils.assertBNEq(b.total, live.usdc);
      Utils.assertBNEq(b.supply, live.supply);
      const expectedPps = live.usdc.times(1e6).idiv(live.supply);
      Utils.assertBNEq(b.pps, expectedPps);
      console.log("share price before: ", live.pps.toFixed(), " after: ", b.pps.toFixed());
      Utils.assertBNGt(live.pps, b.pps);
      Utils.assertBNGt(b.pps, 1e6);
    });

    it("is a no-op to finalize again", async function() {
      const tx = await strategy.finalizeUpgrade({ from: governance });
      assert.equal(hasLog(tx.receipt, WRITTEN_OFF_TOPIC), false);
      await expectRevert(strategy.finalizeUpgrade({ from: farmer1 }), "Not governance");
    });
  });

  describe("Hard work", function() {
    it("sells the pending rewards for USDC and keeps the USDC in the strategy", async function() {
      // whatever is still pending plus some more, so that both reward paths get exercised
      await morphoToken.transfer(STRATEGY, new BigNumber(10e18).toFixed(), { from: morphoWhale });
      await fxnToken.transfer(STRATEGY, new BigNumber(1e18).toFixed(), { from: fxnWhale });
      const b0 = await balances();
      Utils.assertBNGt(b0.morpho, 0);
      Utils.assertBNGt(b0.fxn, 0);
      const profitShareBefore = new BigNumber(await farm.balanceOf(await controller.profitSharingReceiver()));
      const platformFeeBefore = new BigNumber(await weth.balanceOf(await controller.protocolFeeReceiver()));

      await controller.doHardWork(VAULT, { from: governance });

      const b1 = await balances();
      console.log("USDC in the strategy before: ", b0.usdc.toFixed(), " after: ", b1.usdc.toFixed());
      Utils.assertBNEq(b1.morpho, 0);
      Utils.assertBNEq(b1.fxn, 0);
      Utils.assertBNGte(1e3, b1.weth);
      Utils.assertBNGt(b1.usdc, b0.usdc);
      // nothing went anywhere near the Morpho vault
      Utils.assertBNEq(b1.shares, b0.shares);
      // and the proceeds are what the vault sees
      Utils.assertBNEq(b1.invested, b1.usdc);
      Utils.assertBNEq(b1.total, b1.usdc);
      Utils.assertBNEq(b1.inVault, 0);
      Utils.assertBNGt(b1.pps, b0.pps);
      // the fees were taken on the rewards in the usual way: profit share in FARM, platform fee in WETH
      const profitShareAfter = new BigNumber(await farm.balanceOf(await controller.profitSharingReceiver()));
      const platformFeeAfter = new BigNumber(await weth.balanceOf(await controller.protocolFeeReceiver()));
      console.log("profit share (FARM): ", profitShareAfter.minus(profitShareBefore).toFixed(), " platform fee (WETH): ", platformFeeAfter.minus(platformFeeBefore).toFixed());
      Utils.assertBNGt(profitShareAfter, profitShareBefore);
      Utils.assertBNGt(platformFeeAfter, platformFeeBefore);
    });

    it("sells what it can when one reward token cannot be sold", async function() {
      // a dust balance the liquidator refuses next to a real one
      await fxnToken.transfer(STRATEGY, "1", { from: fxnWhale });
      await morphoToken.transfer(STRATEGY, new BigNumber(10e18).toFixed(), { from: morphoWhale });
      const b0 = await balances();

      const tx = await controller.doHardWork(VAULT, { from: governance });

      const b1 = await balances();
      Utils.assertBNEq(b1.morpho, 0);
      Utils.assertBNEq(b1.fxn, 1);
      Utils.assertBNGt(b1.usdc, b0.usdc);
      const strategyLogs = await strategy.getPastEvents("RewardSaleSkipped", { fromBlock: tx.receipt.blockNumber, toBlock: tx.receipt.blockNumber });
      assert.equal(strategyLogs.length, 1);
      assert.equal(strategyLogs[0].args.token, FXN);
      // the dust can be swept by governance so that it does not get in the way
      await strategy.salvage(governance, FXN, 1, { from: governance });
      Utils.assertBNEq(await fxnToken.balanceOf(STRATEGY), 0);
    });

    it("is harmless with nothing to sell", async function() {
      await controller.doHardWork(VAULT, { from: governance });
      const b0 = await balances();
      await Utils.waitHours(12);
      await controller.doHardWork(VAULT, { from: governance });
      const b1 = await balances();
      Utils.assertBNEq(b1.usdc, b0.usdc);
      Utils.assertBNEq(b1.pps, b0.pps);
      Utils.assertBNEq(b1.shares, b0.shares);
    });

    it("can only be run by the vault, the controller or governance", async function() {
      await expectRevert(strategy.doHardWork({ from: farmer1 }), "The sender has to be the controller, governance, or vault");
      await expectRevert(strategy.withdrawToVault(1, { from: farmer1 }), "The sender has to be the controller, governance, or vault");
      await expectRevert(strategy.withdrawAllToVault({ from: farmer1 }), "The sender has to be the controller, governance, or vault");
      await expectRevert(strategy.liquidateRewards({ from: governance }), "only self");
      await expectRevert(strategy.sellReward(MORPHO, { from: governance }), "only self");
    });
  });

  describe("Withdrawals", function() {
    it("pay the holders their share of the USDC, down to the last one", async function() {
      await controller.doHardWork(VAULT, { from: governance });
      const b0 = await balances();
      const autopilotShares = new BigNumber(await vault.balanceOf(AUTOPILOT));
      const hardWorkerShares = new BigNumber(await vault.balanceOf(HARD_WORKER));
      Utils.assertBNEq(autopilotShares.plus(hardWorkerShares), b0.supply);
      Utils.assertBNGt(autopilotShares, 100e6);

      // a partial withdrawal, by assets through the ERC4626 entrypoint the Autopilot's fuse uses,
      // is served from the strategy's idle USDC
      const part = new BigNumber(100e6);
      const assets = b0.total.times(part).idiv(b0.supply);
      const sharesBurnt = assets.times(b0.supply).idiv(b0.total);
      const expected = b0.total.times(sharesBurnt).idiv(b0.supply);
      let paid0 = new BigNumber(await usdc.balanceOf(AUTOPILOT));
      await vault.methods["withdraw(uint256,address,address)"](assets.toFixed(), AUTOPILOT, AUTOPILOT, { from: AUTOPILOT });
      let paid1 = new BigNumber(await usdc.balanceOf(AUTOPILOT));
      console.log("autopilot withdrew ", assets.toFixed(), " USDC of assets and got ", paid1.minus(paid0).toFixed());
      Utils.assertBNEq(paid1.minus(paid0), expected);
      Utils.assertBNGte(assets, expected);
      Utils.assertBNGte(expected.plus(2), assets);
      let b = await balances();
      Utils.assertBNEq(b.usdc, b0.usdc.minus(expected));
      Utils.assertBNEq(b.inVault, 0);
      Utils.assertBNEq(b.supply, b0.supply.minus(sharesBurnt));
      Utils.assertBNGte(b.pps.plus(1), b0.pps);
      Utils.assertBNGte(b0.pps.plus(1), b.pps);

      // the second holder leaves, by shares through the ERC4626 redeem
      paid0 = new BigNumber(await usdc.balanceOf(HARD_WORKER));
      await vault.redeem(hardWorkerShares.toFixed(), HARD_WORKER, HARD_WORKER, { from: HARD_WORKER });
      paid1 = new BigNumber(await usdc.balanceOf(HARD_WORKER));
      console.log("hard worker withdrew all for   ", paid1.minus(paid0).toFixed(), " USDC");
      Utils.assertBNGt(paid1, paid0);

      // the last holder takes everything that is left, through withdrawAllToVault
      paid0 = new BigNumber(await usdc.balanceOf(AUTOPILOT));
      await vault.withdraw(new BigNumber(await vault.balanceOf(AUTOPILOT)).toFixed(), { from: AUTOPILOT });
      paid1 = new BigNumber(await usdc.balanceOf(AUTOPILOT));
      console.log("autopilot withdrew the rest for", paid1.minus(paid0).toFixed(), " USDC");
      b = await balances();
      Utils.assertBNEq(b.supply, 0);
      Utils.assertBNEq(b.usdc, 0);
      Utils.assertBNEq(b.inVault, 0);
      Utils.assertBNEq(b.invested, 0);
      // the written-off shares never moved
      Utils.assertBNEq(b.shares, b0.shares);
    });

    it("are the only way in or out: the vault takes no new deposits", async function() {
      const amount = new BigNumber(1000e6);
      await usdc.approve(VAULT, amount.toFixed(), { from: farmer1 });
      await expectRevert(vault.methods["deposit(uint256)"](amount.toFixed(), { from: farmer1 }), "Too much arb");
      await expectRevert(vault.methods["deposit(uint256,address)"](amount.toFixed(), farmer1, { from: farmer1 }), "Too much arb");
      await expectRevert(vault.depositFor(amount.toFixed(), farmer1, { from: farmer1 }), "Too much arb");
      await expectRevert(vault.mint(new BigNumber(1e6).toFixed(), farmer1, { from: farmer1 }), "Too much arb");
      Utils.assertBNEq(await vault.balanceOf(farmer1), 0);
      // USDC sent straight to the strategy is not a deposit either: it accrues to the holders
      const b0 = await balances();
      await usdc.transfer(STRATEGY, amount.toFixed(), { from: farmer1 });
      const b1 = await balances();
      Utils.assertBNEq(b1.total, b0.total.plus(amount));
      Utils.assertBNEq(b1.supply, b0.supply);
      Utils.assertBNGt(b1.pps, b0.pps);
    });
  });

  describe("Exits", function() {
    it("never wait for the reward sale", async function() {
      // a reward token the liquidator has no route for is skipped, the rest is still sold
      await strategy.addRewardToken(MORPHO_VAULT, { from: governance });
      await morphoToken.transfer(STRATEGY, new BigNumber(10e18).toFixed(), { from: morphoWhale });
      let tx = await controller.doHardWork(VAULT, { from: governance });
      assert.equal(hasLog(tx.receipt, SALE_SKIPPED_TOPIC, MORPHO_VAULT), true, "RewardSaleSkipped(aprUSDC) should be emitted");
      Utils.assertBNEq(await morphoToken.balanceOf(STRATEGY), 0);
      Utils.assertBNEq(await morphoShares.balanceOf(STRATEGY), live.shares);

      // the last leg of the sale (WETH for USDC) refusing a dust amount does block the hard work
      // (the liquidator reverts with "Too little received" below ~4.5e8 wei; topping the strategy up
      // with ~1e9 wei of WETH, or a governance salvage, clears it)...
      await web3.eth.sendTransaction({ from: accounts[2], to: WETH, value: 2000 });
      await weth.transfer(STRATEGY, "2000", { from: accounts[2] });
      await expectRevert.unspecified(controller.doHardWork(VAULT, { from: governance }));

      // ...but never the exit
      const b0 = await balances();
      tx = await strategy.withdrawAllToVault({ from: governance });
      assert.equal(hasLog(tx.receipt, SKIPPED_TOPIC), true, "RewardLiquidationSkipped should be emitted");
      const b1 = await balances();
      Utils.assertBNEq(b1.usdc, 0);
      Utils.assertBNEq(b1.inVault, b0.usdc);
      Utils.assertBNEq(b1.total, b0.total);
      Utils.assertBNEq(b1.pps, b0.pps);
      // the failed sale left everything else where it was
      Utils.assertBNEq(b1.shares, b0.shares);
      Utils.assertBNEq(b1.weth, b0.weth);
      // and governance can clear the dust out of the way
      await strategy.salvage(governance, WETH, b1.weth.toFixed(), { from: governance });
      Utils.assertBNEq(await weth.balanceOf(STRATEGY), 0);
    });

    it("sell the rewards on the way out when they can", async function() {
      await morphoToken.transfer(STRATEGY, new BigNumber(10e18).toFixed(), { from: morphoWhale });
      const b0 = await balances();
      const tx = await strategy.withdrawAllToVault({ from: governance });
      assert.equal(hasLog(tx.receipt, SKIPPED_TOPIC), false);
      const b1 = await balances();
      Utils.assertBNEq(b1.morpho, 0);
      Utils.assertBNEq(b1.usdc, 0);
      Utils.assertBNGt(b1.inVault, b0.usdc);
      Utils.assertBNEq(b1.total, b1.inVault);
    });

    it("move everything to the next strategy on a switch", async function() {
      await controller.doHardWork(VAULT, { from: governance });
      const b0 = await balances();

      // a fresh sunset strategy as the stand-in for whatever comes next
      const nextImpl = await Strategy.new();
      const nextProxy = await StrategyProxy.new(nextImpl.address);
      const next = await Strategy.at(nextProxy.address);
      await next.initializeStrategy(addresses.Storage, VAULT, { from: governance });
      assert.equal(await next.rewardTokens(0), MORPHO);
      assert.equal(await next.rewardTokens(1), FXN);
      assert.equal(await next.morphoVault(), MORPHO_VAULT);

      await vault.announceStrategyUpdate(next.address, { from: governance });
      await Utils.waitHours(13);
      await vault.setStrategy(next.address, { from: governance });

      assert.equal(await vault.strategy(), next.address);
      Utils.assertBNEq(await usdc.balanceOf(STRATEGY), 0);
      Utils.assertBNEq(await vault.underlyingBalanceInVault(), b0.usdc);
      Utils.assertBNEq(await vault.underlyingBalanceWithInvestment(), b0.total);
      Utils.assertBNEq(await vault.getPricePerFullShare(), b0.pps);
      // the written-off shares stay behind in the old strategy, for governance to salvage
      Utils.assertBNEq(await morphoShares.balanceOf(STRATEGY), b0.shares);
    });
  });

  describe("Governance", function() {
    it("can salvage the written-off Morpho shares, but not the USDC", async function() {
      const shares = new BigNumber(await morphoShares.balanceOf(STRATEGY));
      Utils.assertBNGt(shares, 0);
      await expectRevert(strategy.salvage(governance, USDC, 1, { from: governance }), "token is defined as not salvagable");
      await expectRevert(strategy.salvage(farmer1, MORPHO_VAULT, shares.toFixed(), { from: farmer1 }), "Not governance");

      const b0 = await balances();
      await strategy.salvage(governance, MORPHO_VAULT, shares.toFixed(), { from: governance });
      Utils.assertBNEq(await morphoShares.balanceOf(STRATEGY), 0);
      Utils.assertBNEq(await morphoShares.balanceOf(governance), shares);
      // which changes nothing for the depositors
      const b1 = await balances();
      Utils.assertBNEq(b1.invested, b0.invested);
      Utils.assertBNEq(b1.pps, b0.pps);
    });
  });
});
