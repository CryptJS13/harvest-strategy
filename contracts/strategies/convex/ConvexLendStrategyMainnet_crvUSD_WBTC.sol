// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./ConvexLendStrategy.sol";

contract ConvexLendStrategyMainnet_crvUSD_WBTC is ConvexLendStrategy {

  constructor() {}

  function initializeStrategy(
    address _storage,
    address _vault
  ) public initializer {
    address underlying = address(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    address lendingVault = address(0xccd37EB6374Ae5b1f0b85ac97eFf14770e0D0063);
    address rewardPool = address(0xfe382f1Bf78e6D6012cB38C284Fe123ec9821966);
    address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    ConvexLendStrategy.initializeBaseStrategy(
      _storage,
      underlying,
      _vault,
      lendingVault,
      rewardPool,
      crv,
      344
    );
    rewardTokens = [crv, cvx];
  }
}
