//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./MorphoVaultV2Strategy.sol";

contract MorphoVaultStrategyMainnet_BW_AUSD_V2 is MorphoVaultV2Strategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
    address morphoVault = address(0xB344e331A3cDa61D329fb3Cca2Be5942da87c418);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address morpho = address(0x58D97B57BB95320F9a05dC918Aef65434969c2B2);
    MorphoVaultV2Strategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      morphoVault,
      weth
    );
    rewardTokens = [morpho];
    _setDistributionTime(morpho, 172_800); // 48 hours
  }
}
