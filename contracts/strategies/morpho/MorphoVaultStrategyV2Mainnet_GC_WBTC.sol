//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./MorphoVaultStrategyV2.sol";

contract MorphoVaultStrategyV2Mainnet_GC_WBTC is MorphoVaultStrategyV2 {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address morphoVault = address(0x443df5eEE3196e9b2Dd77CaBd3eA76C3dee8f9b2);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address morpho = address(0x58D97B57BB95320F9a05dC918Aef65434969c2B2);
    MorphoVaultStrategyV2.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      morphoVault,
      weth,
      address(0x0)
    );
    rewardTokens = [morpho];
    distributionTime[morpho] = 172_800; // 48 hours
  }
}
