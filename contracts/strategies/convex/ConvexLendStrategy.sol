// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/IERC4626.sol";
import "../../base/interface/convex/IBooster.sol";
import "../../base/interface/convex/IBaseRewardPool.sol";

contract ConvexLendStrategy is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _LENDING_VAULT_SLOT = 0x8b86aeb97224511570debab032f96aaf5e60e935a719498681731f3bbfad60da;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;
  bytes32 internal constant _POOLID_SLOT = 0x3fd729bfa2e28b7806b03a6e014729f59477b530f995be4d51defc9dad94810b;

  // this would be reset on each upgrade
  address[] public rewardTokens;

  constructor() BaseUpgradeableStrategy() {
    assert(_LENDING_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.lendingVault")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
    assert(_POOLID_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.poolId")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _lendingVault,
    address _rewardPool,
    address _rewardToken,
    uint256 _poolId
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _rewardPool,
      _rewardToken,
      harvestMSIG
    );

    address _lpt;
    address booster = IBaseRewardPool(_rewardPool).operator();
    (_lpt,,,,,) = IBooster(booster).poolInfo(_poolId);
    require(_lpt == _lendingVault, "Pool Info does not match underlying");
    require(IERC4626(_lendingVault).asset() == _underlying, "Underlying mismatch");
    _setPoolId(_poolId);
    _setLendingVault(_lendingVault);
  }

  function _rewardPoolBalance() internal view returns (uint256 bal) {
    bal = IBaseRewardPool(rewardPool()).balanceOf(address(this));
  }

  function _exitRewardPool(bool claim) internal {
    uint256 stakedBalance = _rewardPoolBalance();
    if (stakedBalance != 0) {
      IBaseRewardPool(rewardPool()).withdrawAllAndUnwrap(claim);
    }
  }

  function _partialWithdrawalRewardPool(uint256 amount) internal {
    IBaseRewardPool(rewardPool()).withdrawAndUnwrap(amount, false);  //don't claim rewards at this point
  }

  function _enterRewardPool() internal {
    address _lendingVault = lendingVault();
    uint256 entireBalance = IERC20(_lendingVault).balanceOf(address(this));
    address booster = IBaseRewardPool(rewardPool()).operator();
    IERC20(_lendingVault).safeApprove(booster, 0);
    IERC20(_lendingVault).safeApprove(booster, entireBalance);
    IBooster(booster).depositAll(poolId(), true); //deposit and stake
  }

  function currentBalance() public view returns (uint256) {
    address _lendingVault = lendingVault();
    uint256 balance = IERC20(_lendingVault).balanceOf(address(this)).add(_rewardPoolBalance());
    uint256 underlyingBalance = IERC4626(_lendingVault).previewRedeem(balance);
    return underlyingBalance;
  }

  function storedBalance() public view returns (uint256) {
    return getUint256(_STORED_SUPPLIED_SLOT);
  }

  function _updateStoredBalance() internal {
    uint256 balance = currentBalance();
    setUint256(_STORED_SUPPLIED_SLOT, balance);
  }

  function totalFeeNumerator() public view returns (uint256) {
    return strategistFeeNumerator().add(platformFeeNumerator()).add(profitSharingNumerator());
  }

  function pendingFee() public view returns (uint256) {
    return getUint256(_PENDING_FEE_SLOT);
  }

  function _accrueFee() internal {
    uint256 fee;
    if (currentBalance() > storedBalance()) {
      uint256 balanceIncrease = currentBalance().sub(storedBalance());
      fee = balanceIncrease.mul(totalFeeNumerator()).div(feeDenominator());
    }
    setUint256(_PENDING_FEE_SLOT, pendingFee().add(fee));
    _updateStoredBalance();
  }

  function feeFloor() public view virtual returns (uint256) {
    return 0;
  }

  function _handleFee() internal {
    _accrueFee();
    uint256 fee = pendingFee();
    if (fee > feeFloor()) {
      _redeem(fee);
      address _underlying = underlying();
      fee = Math.min(fee, IERC20(_underlying).balanceOf(address(this)));
      uint256 balanceIncrease = fee.mul(feeDenominator()).div(totalFeeNumerator());
      _notifyProfitInRewardToken(_underlying, balanceIncrease);
      setUint256(_PENDING_FEE_SLOT, pendingFee().sub(fee));
    }
  }

  function depositArbCheck() public pure returns (bool) {
    // there's no arb here.
    return true;
  }

  function unsalvagableTokens(address token) public view returns (bool) {
    return (token == rewardToken() || token == underlying());
  }

  /**
  * The strategy invests by supplying the underlying as a collateral.
  */
  function _investAllUnderlying() internal onlyNotPausedInvesting {
    address _underlying = underlying();
    uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
    if (underlyingBalance > 1e1) {
      _supply(underlyingBalance);
    }
    _enterRewardPool();
  }

  /**
  * Exits Moonwell and transfers everything to the vault.
  */
  function withdrawAllToVault() public restricted {
    _liquidateRewards();
    address _underlying = underlying();
    _redeemAll(true);
    // Keep back whatever fee `_handleFee` could not pay out - it is below the dust floor,
    // or the yield source refused the redemption. Handing it to the vault along with
    // everything else would leave `pendingFee` with nothing behind it, and
    // `investedUnderlyingBalance()` would then report less than zero.
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    uint256 fee = pendingFee();
    if (balance > fee) {
      IERC20(_underlying).safeTransfer(vault(), balance.sub(fee));
    }
    _updateStoredBalance();
  }

  function emergencyExit() external onlyGovernance {
    _accrueFee();
    _redeemAll(false);
    _setPausedInvesting(true);
    _updateStoredBalance();
  }

  function continueInvesting() public onlyGovernance {
    _setPausedInvesting(false);
  }

  function withdrawToVault(uint256 amountUnderlying) public restricted {
    _accrueFee();
    address _underlying = underlying();
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    if (amountUnderlying <= balance) {
      IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
      return;
    }
    uint256 toRedeem = amountUnderlying.sub(balance);
    // get some of the underlying
    _redeem(toRedeem);
    balance = IERC20(_underlying).balanceOf(address(this));
    // transfer the amount requested (or the amount we have) back to vault()
    IERC20(_underlying).safeTransfer(vault(), Math.min(amountUnderlying, balance));
    balance = IERC20(_underlying).balanceOf(address(this));
    if (balance > 1e1) {
      _investAllUnderlying();
    }
    _updateStoredBalance();
  }

  /**
  * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
  */
  function doHardWork() public restricted {
    IBaseRewardPool(rewardPool()).getReward();
    _liquidateRewards();
    _investAllUnderlying();
    _updateStoredBalance();
  }

  /**
  * Salvages a token.
  */
  function salvage(address recipient, address token, uint256 amount) public onlyGovernance {
    // To make sure that governance cannot come in and take away the coins
    require(!unsalvagableTokens(token), "token is defined as not salvagable");
    IERC20(token).safeTransfer(recipient, amount);
  }

  function addRewardToken(address _token) public onlyGovernance {
    rewardTokens.push(_token);
  }

  function _liquidateRewards() internal {
    if (!sell()) {
      // Profits can be disabled for possible simplified and rapid exit
      emit ProfitsNotCollected(sell(), false);
      return;
    }
    _handleFee();
    
    address _rewardToken = rewardToken();
    address _universalLiquidator = universalLiquidator();

    for(uint256 i = 0; i < rewardTokens.length; i++){
      address token = rewardTokens[i];
      uint256 balance = IERC20(token).balanceOf(address(this));

      if (balance <= 1e2 || token == _rewardToken) {
        continue;
      }

      IERC20(token).safeApprove(_universalLiquidator, 0);
      IERC20(token).safeApprove(_universalLiquidator, balance);
      IUniversalLiquidator(_universalLiquidator).swap(token, _rewardToken, balance, 1, address(this));
    }

    uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
    _notifyProfitInRewardToken(_rewardToken, rewardBalance);
    uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));

    if (remainingRewardBalance <= 1e2) {
      return;
    }

    address _underlying = underlying();
    if(_underlying != _rewardToken) {
      IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
      IERC20(_rewardToken).safeApprove(_universalLiquidator, remainingRewardBalance);
      IUniversalLiquidator(_universalLiquidator).swap(_rewardToken, _underlying, remainingRewardBalance, 1, address(this));
    }

  }

  /**
  * Returns the current balance.
  */
  function investedUnderlyingBalance() public view returns (uint256) {
    uint256 total = IERC20(underlying()).balanceOf(address(this)).add(storedBalance());
    uint256 fee = pendingFee();
    // Clamped rather than subtracted outright: this is read by every vault entrypoint, so
    // an underflow here would take deposits, withdrawals and the share price down with it.
    return total > fee ? total.sub(fee) : 0;
  }

  function _supply(uint256 amount) internal {
    address _underlying = underlying();
    address _lendingVault = lendingVault();
    IERC20(_underlying).safeApprove(_lendingVault, 0);
    IERC20(_underlying).safeApprove(_lendingVault, amount);
    IERC4626(_lendingVault).deposit(amount, address(this));
  }

  function _redeem(uint256 amountUnderlying) internal {
    address _lendingVault = lendingVault();
    uint256 toRedeem = IERC4626(_lendingVault).previewWithdraw(amountUnderlying);
    _partialWithdrawalRewardPool(toRedeem.add(1));
    IERC4626(_lendingVault).withdraw(amountUnderlying, address(this), address(this));
  }

  function _redeemAll(bool claim) internal {
    _exitRewardPool(claim);
    address _lendingVault = lendingVault();
    if (IERC20(_lendingVault).balanceOf(address(this)) > 0) {
      IERC4626(_lendingVault).redeem(
        IERC20(_lendingVault).balanceOf(address(this)),
        address(this),
        address(this)
      );
    }
  }

  function _setLendingVault (address _target) internal {
    setAddress(_LENDING_VAULT_SLOT, _target);
  }

  function lendingVault() public view returns (address) {
    return getAddress(_LENDING_VAULT_SLOT);
  }

  function _setPoolId(uint256 _value) internal {
    setUint256(_POOLID_SLOT, _value);
  }

  function poolId() public view returns (uint256) {
    return getUint256(_POOLID_SLOT);
  }

  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}