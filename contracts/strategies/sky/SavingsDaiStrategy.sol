// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/IERC4626.sol";

contract SavingsDaiStrategy is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

  // this would be reset on each upgrade
  address[] public rewardTokens;

  constructor() BaseUpgradeableStrategy() {
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _savingsDai,
    address _rewardToken
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _savingsDai,
      _rewardToken,
      harvestMSIG
    );

    require(IERC4626(_savingsDai).asset() == _underlying, "Underlying mismatch");
  }

  function currentBalance() public view returns (uint256) {
    address _rewardPool = rewardPool();
    uint256 underlyingBalance = IERC4626(_rewardPool).previewRedeem(IERC20(_rewardPool).balanceOf(address(this)));
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
      uint256 balanceIncrease = fee.mul(feeDenominator()).div(totalFeeNumerator());
      _redeem(fee);
      address _underlying = underlying();
      if (IERC20(_underlying).balanceOf(address(this)) < fee) {
        balanceIncrease = IERC20(_underlying).balanceOf(address(this)).mul(feeDenominator()).div(totalFeeNumerator());
      }
      _notifyProfitInRewardToken(_underlying, balanceIncrease);
      setUint256(_PENDING_FEE_SLOT, 0);
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
  }

  /**
  * Exits Moonwell and transfers everything to the vault.
  */
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
    address _rewardPool = rewardPool();
    IERC20(_underlying).safeApprove(_rewardPool, 0);
    IERC20(_underlying).safeApprove(_rewardPool, amount);
    IERC4626(_rewardPool).deposit(amount, address(this));
  }

  function _redeem(uint256 amountUnderlying) internal {
    address _rewardPool = rewardPool();
    IERC4626(_rewardPool).withdraw(amountUnderlying, address(this), address(this));
  }

  function _redeemAll() internal {
    address _rewardPool = rewardPool();
    if (IERC20(_rewardPool).balanceOf(address(this)) > 0) {
      IERC4626(_rewardPool).redeem(
        IERC20(_rewardPool).balanceOf(address(this)),
        address(this),
        address(this)
      );
    }
  }

  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}