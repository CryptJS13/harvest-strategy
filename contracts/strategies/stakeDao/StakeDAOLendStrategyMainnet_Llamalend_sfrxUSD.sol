// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDAOLendStrategy.sol";

contract StakeDAOLendStrategyMainnet_Llamalend_sfrxUSD is StakeDAOLendStrategy {
    constructor() {}

    function initializeStrategy(address _storage, address _vault) public initializer {
        address underlying = address(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        address lendingVault = address(0x8E3009b59200668e1efda0a2F2Ac42b24baa2982);
        address rewardPool = address(0x4FD78486951704AC75EEa9464302a1BA31C0d442);
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
