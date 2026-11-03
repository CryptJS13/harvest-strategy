// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/IERC4626.sol";

/**
 * @title FluidLendStrategy
 * @dev A lending strategy that invests underlying assets into a lending pool, providing yield and rewards.
 */
contract EulerLendStrategy is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  bytes32 internal constant _EULER_VAULT_SLOT = 0x041f0cce4414774228cf182e5774425e3ba4c93d299b020dbb41be373a87a9c5;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

  address[] public rewardTokens;

  constructor() BaseUpgradeableStrategy() {
    assert(_EULER_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.eulerVault")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
  }

  /**
   * @notice Initializes the strategy and verifies compatibility with the Fluid lending pool.
   * @param _storage Address of the storage contract.
   * @param _underlying Address of the underlying asset.
   * @param _vault Address of the vault.
   * @param _eulerVault Address of the Euler Vault (Euler lending token).
   * @param _rewardToken Address of the reward token.
   */
  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _eulerVault,
    address _rewardToken
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _eulerVault,
      _rewardToken,
      harvestMSIG
    );

    require(IERC4626(_eulerVault).asset() == _underlying, "Underlying mismatch");
    _setEulerVault(_eulerVault);
  }

  function depositArbCheck() public pure returns (bool) {
    // there's no arb here.
    return true;
  }

  /**
   * @notice Returns the current balance of assets in the strategy.
   * @return Current balance of assets in underlying.
   */
  function currentBalance() public view returns (uint256) {
    address _eulerVault = eulerVault();
    uint256 underlyingBalance = IERC4626(_eulerVault).previewRedeem(IERC20(_eulerVault).balanceOf(address(this)));
    return underlyingBalance;
  }

  /**
   * @notice Returns the last stored balance of assets in the strategy.
   * @return Stored balance of assets.
   */
  function storedBalance() public view returns (uint256) {
    return getUint256(_STORED_SUPPLIED_SLOT);
  }

  /**
   * @notice Updates the stored balance with the current balance.
   */
  function _updateStoredBalance() internal {
    uint256 balance = currentBalance();
    setUint256(_STORED_SUPPLIED_SLOT, balance);
  }

  /**
   * @notice Calculates and returns the total fee numerator.
   * @return Total fee numerator.
   */
  function totalFeeNumerator() public view returns (uint256) {
    return strategistFeeNumerator().add(platformFeeNumerator()).add(profitSharingNumerator());
  }

  /**
   * @notice Returns any accrued but unpaid fees.
   * @return Pending fees.
   */
  function pendingFee() public view returns (uint256) {
    return getUint256(_PENDING_FEE_SLOT);
  }

  /**
   * @notice Accrues fees based on the increase in balance.
   */
  function _accrueFee() internal {
    uint256 fee;
    if (currentBalance() > storedBalance()) {
      uint256 balanceIncrease = currentBalance().sub(storedBalance());
      fee = balanceIncrease.mul(totalFeeNumerator()).div(feeDenominator());
    }
    setUint256(_PENDING_FEE_SLOT, pendingFee().add(fee));
  }

  function feeFloor() public view virtual returns (uint256) {
    return 1e3;
  }

  /**
   * @notice Processes any pending fees, redeems the fee amount, and sends to the controller.
   */
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

  /**
   * @notice Determines if a token is unsalvageable (i.e., cannot be removed from the strategy).
   * @param token Address of the token.
   * @return Boolean indicating if the token is unsalvageable.
   */
  function unsalvagableTokens(address token) public view returns (bool) {
    return (token == rewardToken() || token == underlying() || token == eulerVault());
  }

  /**
   * @notice Invests the entire balance of underlying tokens into the lending pool.
   */
  function _investAllUnderlying() internal onlyNotPausedInvesting {
    address _underlying = underlying();
    uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
    if (underlyingBalance > 10) {
      _supply(underlyingBalance);
    }
  }

  /**
   * @notice Withdraws all assets from the strategy and transfers to the vault.
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

  /**
   * @notice Exits the strategy by redeeming all assets and pauses further investments.
   */
  function emergencyExit() external onlyGovernance {
    _accrueFee();
    _redeemAll();
    _setPausedInvesting(true);
    _updateStoredBalance();
  }

  /**
   * @notice Resumes investing after being paused.
   */
  function continueInvesting() public onlyGovernance {
    _setPausedInvesting(false);
  }

  /**
   * @notice Withdraws a specified amount of underlying assets to the vault.
   * @param amountUnderlying Amount of underlying assets to withdraw.
   */
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
    _redeem(toRedeem);
    balance = IERC20(_underlying).balanceOf(address(this));
    IERC20(_underlying).safeTransfer(vault(), Math.min(amountUnderlying, balance));
    if (balance > 10) {
      _investAllUnderlying();
    }
    _updateStoredBalance();
  }

  /**
   * @notice Executes the main strategy logic including reward liquidation and reinvestment.
   */
  function doHardWork() public restricted {
    _liquidateRewards();
    _investAllUnderlying();
    _updateStoredBalance();
  }

  /**
   * @notice Salvages a token that is not essential to the strategy's core operations.
   * @param recipient Address to receive the salvaged tokens.
   * @param token Address of the token to salvage.
   * @param amount Amount of tokens to salvage.
   */
  function salvage(address recipient, address token, uint256 amount) public onlyGovernance {
    require(!unsalvagableTokens(token), "Token is non-salvageable");
    IERC20(token).safeTransfer(recipient, amount);
  }

  /**
   * @notice Adds a new reward token to the strategy.
   * @param _token Address of the reward token to add.
   */
  function addRewardToken(address _token) public onlyGovernance {
    rewardTokens.push(_token);
  }

  /**
   * @notice Liquidates rewards by converting them to the underlying asset.
   */
  function _liquidateRewards() internal {
    if (!sell()) {
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
   * @notice Returns the total balance of underlying assets held by the strategy.
   * @return Total balance of underlying assets.
   */
  function investedUnderlyingBalance() public view returns (uint256) {
    uint256 total = IERC20(underlying()).balanceOf(address(this)).add(storedBalance());
    uint256 fee = pendingFee();
    // Clamped rather than subtracted outright: this is read by every vault entrypoint, so
    // an underflow here would take deposits, withdrawals and the share price down with it.
    return total > fee ? total.sub(fee) : 0;
  }

  /**
   * @notice Supplies a specified amount of underlying tokens to the lending pool.
   * @param amount Amount of tokens to supply.
   */
  function _supply(uint256 amount) internal {
    address _underlying = underlying();
    address _eulerVault = eulerVault();
    IERC20(_underlying).safeApprove(_eulerVault, 0);
    IERC20(_underlying).safeApprove(_eulerVault, amount);
    IERC4626(_eulerVault).deposit(amount, address(this));
  }

  /**
   * @notice Redeems a specified amount of underlying tokens from the lending pool.
   * @param amountUnderlying Amount of underlying tokens to redeem.
   */
  function _redeem(uint256 amountUnderlying) internal {
    address _eulerVault = eulerVault();
    IERC4626(_eulerVault).withdraw(amountUnderlying, address(this), address(this));
  }

  /**
   * @notice Redeems all assets from the lending pool.
   */
  function _redeemAll() internal {
    address _eulerVault = eulerVault();
    if (IERC20(_eulerVault).balanceOf(address(this)) > 0) {
      IERC4626(_eulerVault).redeem(
        IERC20(_eulerVault).balanceOf(address(this)),
        address(this),
        address(this)
      );
    }
  }

  /**
   * @notice Sets the address of the eulerVault.
   * @param _target Address of the eulerVault.
   */
  function _setEulerVault (address _target) internal {
    setAddress(_EULER_VAULT_SLOT, _target);
  }

  /**
   * @notice Returns the address of the eulerVault.
   * @return Address of the eulerVault.
   */
  function eulerVault() public view returns (address) {
    return getAddress(_EULER_VAULT_SLOT);
  }

  /**
   * @notice Finalizes the upgrade of the strategy.
   */
  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}
