//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./GeneralERC4626Strategy.sol";

contract IPORLendingStrategyMainnet_bdUSD is GeneralERC4626Strategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address fToken = address(0xF8F226dA66244F89e70C5B5D1a5C5b0d505Eb1d8);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    GeneralERC4626Strategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      fToken,
      weth
    );
  }
}
