// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDaoStrategy.sol";

contract StakeDaoStrategyMainnet_CVX_ETH is StakeDaoStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x3A283D9c08E8b55966afb64C515f5143cf907611); // Info -> LP Token address
    address rewardPool = address(0x76CF876c2A1287fE71cde51a587003a32f8630f0); // Info -> Stake DAO Vault
    address curveDeposit = address(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4); // Curve Pool Contract
    address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    StakeDaoStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      rewardPool, // rewardPool
      weth, // depositToken
      0, //depositArrayPosition. Find deposit transaction -> input params
      curveDeposit, // deposit contract: usually underlying. Find deposit transaction -> interacted contract
      2, //nTokens -> total number of deposit tokens
      false //metaPool -> if LP token address == pool address (at curve)
    );
    rewardTokens = [crv];
  }
}
