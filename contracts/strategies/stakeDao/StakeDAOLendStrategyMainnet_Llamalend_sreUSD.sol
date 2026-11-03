// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDAOLendStrategy.sol";

contract StakeDAOLendStrategyMainnet_Llamalend_sreUSD is StakeDAOLendStrategy {
    constructor() {}

    function initializeStrategy(address _storage, address _vault) public initializer {
        address underlying = address(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        address lendingVault = address(0xC32B0Cf36e06c790A568667A17DE80cba95A5Aad);
        address rewardPool = address(0x0DB9f8572abEb2e982782D869e764C9Fa162F2Bb);
        address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);

        StakeDAOLendStrategy.initializeBaseStrategy(
            _storage,
            underlying,
            _vault,
            lendingVault,
            rewardPool,
            crv
        );
        rewardTokens = [crv];
    }
}
