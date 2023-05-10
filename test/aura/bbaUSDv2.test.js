const config = require('./import/bbaUSDv2.config.json');
const { AuraULTest } = require("./utils/ul.test.js");

//This test was developed at blockNumber 17187600
const Strategy = artifacts.require("AuraStrategyMainnet_bbaUSD_v2");

// Vanilla Mocha test. Increased compatibility with tools that integrate Mocha.
describe("Mainnet Aura aurabb-a-USD V3 pool", function() {
  let auraULTest = new AuraULTest();

  before(async function() {
    const result = await auraULTest.setupTest(
      config.lpTokens.bb_a_USD.address, 
      config.lpTokens.bb_a_USD.whale,
      [], 
      config.setLiquidationPath,
      Strategy);
  });

  describe("Happy path", function() {
    it("Farmer should earn money", async function() {
      await auraULTest.testHappyPath(config.relatedTokens.aura, true);
    });
  });
});
