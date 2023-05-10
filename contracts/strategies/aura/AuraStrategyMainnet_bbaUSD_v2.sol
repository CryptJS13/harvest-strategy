//SPDX-License-Identifier: Unlicense
pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "./base/AuraStrategyBatchSwapUL.sol";

contract AuraStrategyMainnet_bbaUSD_v2 is AuraStrategyBatchSwapUL {

    constructor() public {}

    function initializeStrategy(
        address _storage, // Harvest: Storage
        address _vault // Harvest: Vault
    ) public initializer {
        address underlying = address(0xfeBb0bbf162E64fb9D0dfe186E517d84C395f016); // Balancer: Balancer Aave Boosted StablePool
        address rewardPool = address(0xD48451A61d5190a1Ba7C9D17056490cB5d50999d); // Aura: Balancer Aave Boosted StablePool Aura Deposit Vault
        bytes32 wETH_USDC = bytes32(0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019);
        bytes32 USDC_bbaUSDC = bytes32(0xcbfa4532d8b2ade2c261d3dd5ef2a2284f7926920000000000000000000004fa);
        bytes32 bbaUSDC_bbaUSD = bytes32(0xfebb0bbf162e64fb9d0dfe186e517d84c395f016000000000000000000000502);
        address usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address bbaUSDC = address(0xcbFA4532D8B2ade2C261D3DD5ef2A2284f792692);
        address bbaUSD = address(0xfeBb0bbf162E64fb9D0dfe186E517d84C395f016);

        // WETH -> USDC -> bb-a-USDC -> bb-a-USD
        swapAssets = [weth, usdc, bbaUSDC, bbaUSD];
        swapPoolIds = [wETH_USDC, USDC_bbaUSDC, bbaUSDC_bbaUSD];

        rewardTokens = [bal, aura];
        storedLiquidationPaths[bal][weth] = [bal, weth];
        storedLiquidationDexes[bal][weth] = [balancerDex];
        storedLiquidationPaths[aura][weth] = [aura, weth];
        storedLiquidationDexes[aura][weth] = [balancerDex];
        AuraStrategyBatchSwapUL.initializeBaseStrategy(
            _storage,
            underlying,
            _vault,
            rewardPool,
            81, // Aura: PoolId
            weth, //Balancer: Deposit Token
            500
        );
    }
}
