// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDaoStrategy.sol";

contract StakeDaoStrategyMainnet_stETH_ng is StakeDaoStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x21E27a5E5513D6e65C4f830167390997aA84843a); // Info -> LP Token address
    address rewardPool = address(0x075e0F745c3518d26B5Ae93e2483Ecc80396db8f); // Info -> Stake DAO Vault
    address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    StakeDaoStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      rewardPool, // rewardPool
      weth, // depositToken
      0, //depositArrayPosition. Find deposit transaction -> input params
      underlying, // deposit contract: usually underlying. Find deposit transaction -> interacted contract
      2, //nTokens -> total number of deposit tokens
      false //metaPool -> if LP token address == pool address (at curve)
    );
    rewardTokens = [crv];
  }
}
