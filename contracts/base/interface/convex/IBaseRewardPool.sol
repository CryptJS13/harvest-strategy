// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IBaseRewardPool {
    function balanceOf(address account) external view returns(uint256 amount);
    function pid() external view returns (uint256 _pid);
    function stakingToken() external view returns (address _stakingToken);
    function getReward() external;
    function stake(uint256 _amount) external;
    function stakeAll() external;
    function withdraw(uint256 amount, bool claim) external;
    function withdrawAll(bool claim) external;
    function withdrawAndUnwrap(uint256 amount, bool claim) external;
    function withdrawAllAndUnwrap(bool claim) external;
    function operator() external view returns (address _operator);
}
