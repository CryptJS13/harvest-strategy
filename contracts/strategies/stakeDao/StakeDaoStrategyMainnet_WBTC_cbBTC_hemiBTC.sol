// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDaoStrategy.sol";

contract StakeDaoStrategyMainnet_WBTC_cbBTC_hemiBTC is StakeDaoStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x66039342C66760874047c36943B1e2d8300363BB); // Info -> LP Token address
    address rewardPool = address(0x3C69C2F6852C65CDD8e02C4FdA1A7221CB79DDd5); // Info -> Stake DAO Vault
    address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    StakeDaoStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      rewardPool, // rewardPool
      wbtc, // depositToken
      0, //depositArrayPosition. Find deposit transaction -> input params
      underlying, // deposit contract: usually underlying. Find deposit transaction -> interacted contract
      3, //nTokens -> total number of deposit tokens
      true //metaPool -> if LP token address == pool address (at curve)
    );
    rewardTokens = [crv];
  }
}
