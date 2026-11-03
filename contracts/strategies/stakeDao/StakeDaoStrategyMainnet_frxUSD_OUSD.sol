// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDaoStrategy.sol";

contract StakeDaoStrategyMainnet_frxUSD_OUSD is StakeDaoStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x68d03Ed49800e92D7Aa8aB171424007e55Fd1F49); // Info -> LP Token address
    address rewardPool = address(0x715AAAc9b7c35b88299376147eE7B0c09A0F1B22); // Info -> Stake DAO Vault
    address frxusd = address(0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29);
    address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    StakeDaoStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      rewardPool, // rewardPool
      frxusd, // depositToken
      0, //depositArrayPosition. Find deposit transaction -> input params
      underlying, // deposit contract: usually underlying. Find deposit transaction -> interacted contract
      2, //nTokens -> total number of deposit tokens
      true //metaPool -> if LP token address == pool address (at curve)
    );
    rewardTokens = [crv];
  }
}
