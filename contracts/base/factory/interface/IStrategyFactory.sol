// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IStrategyFactory {
  function deploy(address _storage, address _vault, address _providedStrategyAddress) external returns (address);
}
