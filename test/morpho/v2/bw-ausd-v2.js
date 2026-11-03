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

//const Strategy = artifacts.require("");
const Strategy = artifacts.require("MorphoVaultStrategyMainnet_BW_AUSD_V2");

// Developed and tested at blockNumber 25891800

// Vanilla Mocha test. Increased compatibility with tools that integrate Mocha.
describe("Mainnet Morpho Vault V2 Bitwise Premium RWA AUSD", function() {
  let accounts;

  // external contracts
  let underlying;

  // external setup
  let underlyingWhale = "0x080f646713bce0da8c08770d407818de47639cf5";
  let morphoWhale = "0x72b23AeBbD4aBfc1cEA755686710E74c93696Fae";
  let morpho = "0x58D97B57BB95320F9a05dC918Aef65434969c2B2";
  let ausd = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a";
  let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  let weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  let morphoToken;
  let farmToken;
  let wethToken;

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
    underlying = await IERC20.at(ausd);
    console.log("Fetching Underlying at: ", underlying.address);
    morphoToken = await IERC20.at(morpho);
    farmToken = await IERC20.at(addresses.FARM);
    wethToken = await IERC20.at(weth);
  }

  async function setupBalance(){
    let etherGiver = accounts[9];
    await web3.eth.sendTransaction({ from: etherGiver, to: underlyingWhale, value: 10e18});
    await web3.eth.sendTransaction({ from: etherGiver, to: morphoWhale, value: 10e18});

    // Keep part of the whale balance behind, it is used to simulate the Merkl incentive below
    farmerBalance = new BigNumber(await underlying.balanceOf(underlyingWhale)).dividedToIntegerBy(4).toFixed();
    await underlying.transfer(farmer1, farmerBalance, { from: underlyingWhale });
  }

  before(async function() {
    governance = addresses.Governance;
    accounts = await web3.eth.getAccounts();

    farmer1 = accounts[1];

    // impersonate accounts
    await impersonates([governance, underlyingWhale, morphoWhale, addresses.ULOwner]);

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

    await strategy.toggleMerklOperator("0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae", "0x6a74649aCFD7822ae8Fb78463a9f2192752E5Aa2", {from: governance});
    await strategy.toggleMerklOperator("0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae", "0xFeed4C53d827AEBEBED6066788065eA1027C7e70", {from: governance});
  });

  describe("Happy path", function() {
    it("Farmer should earn money", async function() {
      let farmerOldBalance = new BigNumber(await underlying.balanceOf(farmer1));
      let profitShareOldBalance = new BigNumber(await farmToken.balanceOf(addresses.ProfitShare));
      let platformOldBalance = new BigNumber(await wethToken.balanceOf(addresses.CommunityMsig));
      await depositVault(farmer1, underlying, vault, farmerBalance);

      let hours = 25;
      let blocksPerHour = 3600;
      let oldSharePrice;
      let newSharePrice;

      for (let i = 0; i < hours; i++) {
        console.log("loop ", i);

        if (i % 3 == 0) {
          await morphoToken.transfer(strategy.address, new BigNumber(1e18), {from: morphoWhale});
        }

        oldSharePrice = new BigNumber(await vault.getPricePerFullShare());
        await controller.doHardWork(vault.address, { from: governance });
        newSharePrice = new BigNumber(await vault.getPricePerFullShare());

        console.log("old shareprice: ", oldSharePrice.toFixed());
        console.log("new shareprice: ", newSharePrice.toFixed());
        console.log("growth: ", newSharePrice.toFixed() / oldSharePrice.toFixed());

        apr = (newSharePrice.toFixed()/oldSharePrice.toFixed()-1)*(24/(blocksPerHour/1800))*365;
        apy = ((newSharePrice.toFixed()/oldSharePrice.toFixed()-1)*(24/(blocksPerHour/1800))+1)**365;

        console.log("instant APR:", apr*100, "%");
        console.log("instant APY:", (apy-1)*100, "%");

        await Utils.advanceNBlock(blocksPerHour);
      }
      
      await vault.withdraw(new BigNumber(await vault.balanceOf(farmer1)).toFixed(), { from: farmer1 });
      let farmerNewBalance = new BigNumber(await underlying.balanceOf(farmer1));
      Utils.assertBNGt(farmerNewBalance, farmerOldBalance);

      let profitShareNewBalance = new BigNumber(await farmToken.balanceOf(addresses.ProfitShare));
      let platformNewBalance = new BigNumber(await wethToken.balanceOf(addresses.CommunityMsig));
      console.log("profit share FARM gained: ", profitShareNewBalance.minus(profitShareOldBalance).toFixed());
      console.log("platform fee WETH gained: ", platformNewBalance.minus(platformOldBalance).toFixed());
      Utils.assertBNGt(profitShareNewBalance, profitShareOldBalance);
      Utils.assertBNGt(platformNewBalance, platformOldBalance);
      let pendingFeeEnd = new BigNumber(await strategy.pendingFee());
      console.log("pendingFee left: ", pendingFeeEnd.toFixed());
      Utils.assertBNGte(new BigNumber(1e3), pendingFeeEnd);

      apr = (farmerNewBalance.toFixed()/farmerOldBalance.toFixed()-1)*(24/(blocksPerHour*hours/1800))*365;
      apy = ((farmerNewBalance.toFixed()/farmerOldBalance.toFixed()-1)*(24/(blocksPerHour*hours/1800))+1)**365;

      console.log("earned!");
      console.log("APR:", apr*100, "%");
      console.log("APY:", (apy-1)*100, "%");

      await strategy.withdrawAllToVault({from:governance}); // making sure can withdraw all for a next switch

    });
  });
});
