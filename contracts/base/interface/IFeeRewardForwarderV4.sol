//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IFeeRewardForwarderV4 {
    function setTokenPool(address _pool) external;

    function poolNotifyFixedTarget(address _token, uint256 _amount) external;
    function profitSharingPool() external view returns (address);
}
