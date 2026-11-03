// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./StakeDAOLendStrategy.sol";

contract StakeDAOLendStrategyMainnet_Llamalend_tBTC is StakeDAOLendStrategy {
    constructor() {}

    function initializeStrategy(address _storage, address _vault) public initializer {
        address underlying = address(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        address lendingVault = address(0xb2b23C87a4B6d1b03Ba603F7C3EB9A81fDC0AAC9);
        address rewardPool = address(0x977DdCA6f9E088094EEE9567E6d5906B1a1e94d2);
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
