// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/dolomite/IDolomiteMargin.sol";
import "../../base/interface/dolomite/IDepositWithdraw.sol";

import "hardhat/console.sol";

contract DolomiteLendStrategy is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _MARKET_ID_SLOT = 0x54fed29e040f8360ca8b822de4be5728a7f0714b74e8d5dd23a1d1ac0c75c6a7;
  bytes32 internal constant _DOLOMITE_MARGIN_SLOT = 0xeb52083a303441dc22b6905f2ddc3b6ee13a44944ed7f2ebb0bcb3baf59e4e61;
  bytes32 internal constant _DEPOSIT_WITHDRAW_SLOT = 0x096b7d9b1b276278667b14db2373be3a19524b5b48b8b667178d1ae019f52912;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

  // this would be reset on each upgrade
  address[] public rewardTokens;

  constructor() BaseUpgradeableStrategy() {
    assert(_MARKET_ID_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.marketId")) - 1));
    assert(_DOLOMITE_MARGIN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.dolomiteMargin")) - 1));
    assert(_DEPOSIT_WITHDRAW_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.depositWithdraw")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _dolomiteMargin,
    address _depositWithdraw,
    uint256 _marketId,
    address _rewardToken
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _dolomiteMargin,
      _rewardToken,
      harvestMSIG
    );

    require(IDolomiteMargin(_dolomiteMargin).getMarketIdByTokenAddress(_underlying) == _marketId, "Underlying mismatch");
    _setDolomiteMargin(_dolomiteMargin);
    _setDepositWithdraw(_depositWithdraw);
    _setMarketId(_marketId);
  }

  function currentBalance() public view returns (uint256) {
    IDolomiteMargin.Info memory account;
    account.owner = address(this);
    IDolomiteMargin.Wei memory balanceInfo = IDolomiteMargin(dolomiteMargin()).getAccountWei(account, marketId());
    uint256 underlyingBalance = balanceInfo.value;
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
  }

  function feeFloor() public view virtual returns (uint256) {
    return 1e18;
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
    if (underlyingBalance > 0) {
      _supply(underlyingBalance);
    }
  }

  function withdrawAllToVault() public restricted {
    _liquidateRewards();
    address _underlying = underlying();
    _redeemAll();
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
    _redeemAll();
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
      _updateStoredBalance();
      return;
    }
    uint256 toRedeem = amountUnderlying.sub(balance);
    // get some of the underlying
    _redeem(toRedeem);
    balance = IERC20(_underlying).balanceOf(address(this));
    // transfer the amount requested (or the amount we have) back to vault()
    IERC20(_underlying).safeTransfer(vault(), Math.min(amountUnderlying, balance));
    balance = IERC20(_underlying).balanceOf(address(this));
    if (balance > 1e3) {
      _investAllUnderlying();
    }
    _updateStoredBalance();
  }

  /**
  * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
  */
  function doHardWork() public restricted {
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
    for (uint256 i; i < rewardTokens.length; i++) {
      address token = rewardTokens[i];
      uint256 balance = IERC20(token).balanceOf(address(this));
      if (balance > 0 && token != _rewardToken){
        IERC20(token).safeApprove(_universalLiquidator, 0);
        IERC20(token).safeApprove(_universalLiquidator, balance);
        IUniversalLiquidator(_universalLiquidator).swap(token, _rewardToken, balance, 1, address(this));
      }
    }
    uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
    if (rewardBalance <= 1e12) {
      return;
    }
    _notifyProfitInRewardToken(_rewardToken, rewardBalance);
    uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));

    if (remainingRewardBalance == 0) {
      return;
    }
  
    address _underlying = underlying();
    if (_underlying != _rewardToken) {
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
    address _depositWithdraw = depositWithdraw();
    IERC20(_underlying).safeApprove(_depositWithdraw, 0);
    IERC20(_underlying).safeApprove(_depositWithdraw, amount);
    uint256 accountNumber = IDepositWithdraw(_depositWithdraw).DEFAULT_ACCOUNT_NUMBER();
    console.log("accountNumber:", accountNumber);
    IDepositWithdraw(_depositWithdraw).depositWei(0, accountNumber, marketId(), amount, 0);
  }

  function _redeem(uint256 amountUnderlying) internal {
    address _depositWithdraw = depositWithdraw();
    uint256 accountNumber = IDepositWithdraw(_depositWithdraw).DEFAULT_ACCOUNT_NUMBER();
    IDepositWithdraw(_depositWithdraw).withdrawWei(
      0,
      accountNumber,
      marketId(),
      amountUnderlying,
      1
    );
  }

  function _redeemAll() internal {
    address _depositWithdraw = depositWithdraw();
    uint256 accountNumber = IDepositWithdraw(_depositWithdraw).DEFAULT_ACCOUNT_NUMBER();
    IDepositWithdraw(_depositWithdraw).withdrawWei(
      0,
      accountNumber,
      marketId(),
      currentBalance(),
      1
    );
  }

  function _setDolomiteMargin (address _target) internal {
    setAddress(_DOLOMITE_MARGIN_SLOT, _target);
  }

  function dolomiteMargin() public view returns (address) {
    return getAddress(_DOLOMITE_MARGIN_SLOT);
  }

  function _setDepositWithdraw (address _target) internal {
    setAddress(_DEPOSIT_WITHDRAW_SLOT, _target);
  }

  function depositWithdraw() public view returns (address) {
    return getAddress(_DEPOSIT_WITHDRAW_SLOT);
  }

  function _setMarketId (uint256 _target) internal {
    setUint256(_MARKET_ID_SLOT, _target);
  }

  function marketId() public view returns (uint256) {
    return getUint256(_MARKET_ID_SLOT);
  }

  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}