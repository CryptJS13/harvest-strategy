// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDAOLendStrategy.sol";

contract StakeDAOLendStrategyMainnet_Llamalend_wstETH is StakeDAOLendStrategy {
    constructor() {}

    function initializeStrategy(address _storage, address _vault) public initializer {
        address underlying = address(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        address lendingVault = address(0x21CF1c5Dc48C603b89907FE6a7AE83EA5e3709aF);
        address rewardPool = address(0xc4b246888399f926456860C51a09ad7336Ba3788);
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
