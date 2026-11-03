// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./ConvexStrategy.sol";

contract ConvexStrategyMainnet_frxUSD_OUSD is ConvexStrategy {
    constructor() {}

    function initializeStrategy(
        address _storage,
        address _vault
    ) public initializer {
        address underlying = address(
            0x68d03Ed49800e92D7Aa8aB171424007e55Fd1F49
        ); // Info -> LP Token address
        address rewardPool = address(
            0x42Cf537ddBa32EA5EdF70417a9242788b4523a75
        ); // Info -> Rewards contract address
        address crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
        address cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
        address frxusd = address(0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29);
        ConvexStrategy.initializeBaseStrategy(
            _storage,
            underlying,
            _vault,
            rewardPool, // rewardPool
            532, // Pool id: Info -> Rewards contract address -> read -> pid
            frxusd, // depositToken
            0, //depositArrayPosition. Find deposit transaction -> input params
            underlying, // deposit contract: usually underlying. Find deposit transaction -> interacted contract
            2, //nTokens -> total number of deposit tokens
            true //metaPool -> if LP token address == pool address (at curve). For 2 crypto, if it's stable_swap LP then true else false.
        );
        rewardTokens = [crv, cvx];
    }
}
