//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./MorphoVaultSunsetStrategy.sol";

/**
 * Sunset of the Apostro Resolv USDC strategy (proxy 0x9867C2383dD0747a5a92F8Fdc2f3c95649D92153,
 * previously MorphoVaultStrategyV2Mainnet_AR_USDC). The Apostro Resolv USDC Morpho vault can no
 * longer be withdrawn from; the funds stuck there were compensated in USDC, paid to the strategy.
 */
contract MorphoVaultSunsetStrategyMainnet_AR_USDC is MorphoVaultSunsetStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address morphoVault = address(0x214B47C50057eFaa7adc1B1C2608C3751Cd77D78);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address morpho = address(0x58D97B57BB95320F9a05dC918Aef65434969c2B2);
    address fxn = address(0x365AccFCa291e7D3914637ABf1F7635dB165Bb09);
    MorphoVaultSunsetStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      morphoVault,
      weth,
      address(0x15568A3361a2501181daC9309772cae14156CF9E)
    );
    rewardTokens = [morpho, fxn];
  }
}
