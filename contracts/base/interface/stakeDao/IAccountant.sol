//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IAccountant {
    function claim(address[] calldata _gauges, bytes[] calldata harvestData) external;
}