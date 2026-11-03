//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./MorphoVaultV2Strategy.sol";

contract MorphoVaultStrategyMainnet_SHP_USDT_V2 is MorphoVaultV2Strategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address morphoVault = address(0xbeef003C68896c7D2c3c60d363e8d71a49Ab2bf9);
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
