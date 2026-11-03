// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDaoStrategy.sol";

contract StakeDaoStrategyMainnet_PYUSD_crvUSD is StakeDaoStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0x625E92624Bc2D88619ACCc1788365A69767f6200); // Info -> LP Token address
    address rewardPool = address(0x0F67C05A034fEC0183ad74d3be42c8Ba27F6c4c4); // Info -> Stake DAO Vault
    address crvusd = address(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    StakeDaoStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      rewardPool, // rewardPool
      crvusd, // depositToken
      1, //depositArrayPosition. Find deposit transaction -> input params
      underlying, // deposit contract: usually underlying. Find deposit transaction -> interacted contract
      2, //nTokens -> total number of deposit tokens
      true //metaPool -> if LP token address == pool address (at curve)
    );
    rewardTokens = [crv];
  }
}
