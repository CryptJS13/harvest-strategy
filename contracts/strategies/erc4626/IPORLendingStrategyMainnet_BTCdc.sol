//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./GeneralERC4626Strategy.sol";

contract IPORLendingStrategyMainnet_BTCdc is GeneralERC4626Strategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address fToken = address(0x7659fc26bf3A63E8133BbECB7E16ACD48EE8E292);
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
