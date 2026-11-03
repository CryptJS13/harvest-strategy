//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IStakeVault {
    function ACCOUNTANT() external view returns (address);
    function gauge() external view returns (address);
}