// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/morpho/IMorphoVault.sol";

contract MorphoVaultStrategy is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _MORPHO_VAULT_SLOT = 0xf5b51c17c9e35d4327e4aa5b82628726ecdd06e6cb73d4658ac1e871f3879ea3;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

    // this would be reset on each upgrade
  address[] public rewardTokens;

  mapping(address => uint256) public rewardBalanceLast;
  mapping(address => uint256) public lastRewardTime;
  mapping(address => uint256) public rewardPerSec;

  constructor() BaseUpgradeableStrategy() {
    assert(_MORPHO_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.morphoVault")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _morphoVault,
    address _rewardToken
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _morphoVault,
      _rewardToken,
      harvestMSIG
    );

    require(IMorphoVault(_morphoVault).asset() == _underlying, "Underlying mismatch");
    _setMorphoVault(_morphoVault);
  }

  function currentSupplied() public view returns (uint256) {
    address _morphoVault = morphoVault();
    return IMorphoVault(_morphoVault).convertToAssets(IMorphoVault(_morphoVault).balanceOf(address(this)));
  }

  function storedSupplied() public view returns (uint256) {
    return getUint256(_STORED_SUPPLIED_SLOT);
  }

  function _updateStoredSupplied() internal {
    setUint256(_STORED_SUPPLIED_SLOT, currentSupplied());
  }

  function totalFeeNumerator() public view returns (uint256) {
    return strategistFeeNumerator().add(platformFeeNumerator()).add(profitSharingNumerator());
  }

  function pendingFee() public view returns (uint256) {
    return getUint256(_PENDING_FEE_SLOT);
  }

  function _accrueFee() internal {
    uint256 fee;
    if (currentSupplied() > storedSupplied()) {
      uint256 balanceIncrease = currentSupplied().sub(storedSupplied());
      fee = balanceIncrease.mul(totalFeeNumerator()).div(feeDenominator());
    }
    setUint256(_PENDING_FEE_SLOT, pendingFee().add(fee));
  }

  function feeFloor() public view virtual returns (uint256) {
    return 1e4;
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
    return (token == underlying() || token == morphoVault());
  }

  /**
  * Exits Moonwell and transfers everything to the vault.
  */
  function withdrawAllToVault() public restricted {
    address _underlying = underlying();
    _handleFee();
    _redeemMaximum();
    // Keep back whatever fee `_handleFee` could not pay out - it is below the dust floor,
    // or the yield source refused the redemption. Handing it to the vault along with
    // everything else would leave `pendingFee` with nothing behind it, and
    // `investedUnderlyingBalance()` would then report less than zero.
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    uint256 fee = pendingFee();
    if (balance > fee) {
      IERC20(_underlying).safeTransfer(vault(), balance.sub(fee));
    }
    _updateStoredSupplied();
  }

  function emergencyExit() external onlyGovernance {
    _accrueFee();
    _redeemMaximum();
    _updateStoredSupplied();
  }

  function withdrawToVault(uint256 amountUnderlying) public restricted {
    _accrueFee();
    address _underlying = underlying();
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    if (amountUnderlying <= balance) {
      IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
      _updateStoredSupplied();
      return;
    }
    uint256 toRedeem = amountUnderlying.sub(balance);
    // get some of the underlying
    _redeem(toRedeem);
    // transfer the amount requested (or the amount we have) back to vault()
    IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
    balance = IERC20(_underlying).balanceOf(address(this));
    if (balance > 0) {
      _supply(balance);
    }
    _updateStoredSupplied();
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
    address _rewardToken = rewardToken();
    address _universalLiquidator = universalLiquidator();
    for (uint256 i; i < rewardTokens.length; i++) {
      address token = rewardTokens[i];
      uint256 balance = IERC20(token).balanceOf(address(this));
      if (balance > rewardBalanceLast[token]) {
        _updateDist(balance, token);
      }
      balance = _getAmt(token);
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

  function _updateDist(uint256 balance, address token) internal {
    rewardBalanceLast[token] = balance;
    lastRewardTime[token] = block.timestamp.sub(86400);
    rewardPerSec[token] = balance.div(691200);
  }

  function _getAmt(address token) internal returns (uint256) {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 earned = Math.min(block.timestamp.sub(lastRewardTime[token]).mul(rewardPerSec[token]), balance);
    rewardBalanceLast[token] = balance.sub(earned);
    lastRewardTime[token] = block.timestamp;
    return earned;
  }

  /**
  * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
  */
  function doHardWork() public restricted {
    _handleFee();
    _liquidateRewards();
    _supply(IERC20(underlying()).balanceOf(address(this)));
    _updateStoredSupplied();
  }

  /**
  * Salvages a token.
  */
  function salvage(address recipient, address token, uint256 amount) public onlyGovernance {
    // To make sure that governance cannot come in and take away the coins
    require(!unsalvagableTokens(token), "token is defined as not salvagable");
    IERC20(token).safeTransfer(recipient, amount);
  }

  /**
  * Returns the current balance.
  */
  function investedUnderlyingBalance() public view returns (uint256) {
    uint256 total = IERC20(underlying()).balanceOf(address(this)).add(storedSupplied());
    uint256 fee = pendingFee();
    // Clamped rather than subtracted outright: this is read by every vault entrypoint, so
    // an underflow here would take deposits, withdrawals and the share price down with it.
    return total > fee ? total.sub(fee) : 0;
  }

  /**
  * Supplies to Moonwel
  */
  function _supply(uint256 amount) internal {
    if (amount == 0){
      return;
    }
    address _underlying = underlying();
    address _morphoVault = morphoVault();
    IERC20(_underlying).safeApprove(_morphoVault, 0);
    IERC20(_underlying).safeApprove(_morphoVault, amount);
    IMorphoVault(_morphoVault).deposit(amount, address(this));
  }

  function _redeem(uint256 amountUnderlying) internal {
    if (amountUnderlying == 0){
      return;
    }
    IMorphoVault(morphoVault()).withdraw(amountUnderlying, address(this), address(this));
  }

  function _redeemMaximum() internal {
    // The fee is deliberately left supplied, plus one wei of rounding margin: it keeps
    // `withdraw` from asking the Morpho vault for more than the shares can cover.
    uint256 supplied = currentSupplied();
    uint256 fee = pendingFee().add(1);
    if (supplied > fee) {
      _redeem(supplied.sub(fee));
    }
  }

  function _setMorphoVault (address _target) internal {
    setAddress(_MORPHO_VAULT_SLOT, _target);
  }

  function morphoVault() public view returns (address) {
    return getAddress(_MORPHO_VAULT_SLOT);
  }

  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}