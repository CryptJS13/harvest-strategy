//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./InactiveVaultERC4626Strategy.sol";

/**
 * @dev Inactive vault strategy for USDC, parking the funds in the Gauntlet USDC Core Morpho vault.
 */
contract InactiveVaultERC4626StrategyMainnet_USDC is InactiveVaultERC4626Strategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address erc4626Vault = address(0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    InactiveVaultERC4626Strategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      erc4626Vault,
      weth
    );
  }
}
