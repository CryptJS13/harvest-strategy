// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

/**
 * @dev Minimal interface for the in-kind functions the strategy must expose.
 * Only called while in-kind redemptions are explicitly enabled by governance,
 * so strategies without these functions remain compatible with these vaults.
 */
interface IInKindStrategy {
    function withdrawInKind(uint256 shareNumerator, uint256 shareDenominator, address receiver) external returns (uint256);
    function previewWithdrawInKind(uint256 shareNumerator, uint256 shareDenominator) external view returns (uint256);
    function syncBalance() external;
    function syncedInvestedUnderlyingBalance() external view returns (uint256);
    function rewardPool() external view returns (address);
}
