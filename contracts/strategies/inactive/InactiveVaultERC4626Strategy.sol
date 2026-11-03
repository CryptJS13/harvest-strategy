// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IController.sol";
import "../../base/interface/IRewardForwarder.sol";
import "../../base/interface/IERC4626.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";

/**
 * @title InactiveVaultERC4626Strategy
 * @dev Strategy for vaults that have been turned inactive. The underlying is parked in a plain
 *      ERC4626 vault so that it is not sitting idle, but 100% of the yield it generates is marked
 *      as fee and forwarded to the fee recipients (profit sharing, platform, strategist) in the
 *      usual proportions. Depositors of an inactive vault keep their principal at a flat share
 *      price and do not earn any yield.
 *
 *      Derived from the general ERC4626 strategy: the accounting is identical, except that the
 *      fee taken on a balance increase is the full increase instead of `totalFeeNumerator` of it,
 *      and there is no reward token handling (a plain ERC4626 vault has no reward emissions; any
 *      token that shows up here can be swept by governance with `salvage`).
 */
contract InactiveVaultERC4626Strategy is BaseUpgradeableStrategy {

  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _FTOKEN_SLOT = 0x462e4d44c9bae3e0ee3d71929710bef82ca7c929ce31980e75572ea415835b0e;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

  constructor() BaseUpgradeableStrategy() {
    assert(_FTOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.fToken")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
  }

  /**
   * @notice Initializes the strategy and verifies compatibility with the ERC4626 vault.
   * @param _storage Address of the storage contract.
   * @param _underlying Address of the underlying asset.
   * @param _vault Address of the (inactive) Harvest vault.
   * @param _fToken Address of the fToken (ERC4626 compliant vault token).
   * @param _rewardToken Address of the reward token.
   */
  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _fToken,
    address _rewardToken
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _fToken,
      _rewardToken,
      harvestMSIG
    );

    require(IERC4626(_fToken).asset() == _underlying, "Underlying mismatch");
    _setFToken(_fToken);
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
    address _fToken = fToken();
    uint256 underlyingBalance = IERC4626(_fToken).convertToAssets(IERC20(_fToken).balanceOf(address(this)));
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
    setUint256(_STORED_SUPPLIED_SLOT, currentBalance());
  }

  /**
   * @notice Calculates and returns the total fee numerator.
   * @return Total fee numerator.
   */
  function totalFeeNumerator() public view returns (uint256) {
    return strategistFeeNumerator() + platformFeeNumerator() + profitSharingNumerator();
  }

  /**
   * @notice Returns any accrued but unpaid fees.
   * @return Pending fees.
   */
  function pendingFee() public view returns (uint256) {
    return getUint256(_PENDING_FEE_SLOT);
  }

  /**
   * @notice Accrues the fee on the increase in balance. The vault is inactive, so the whole
   *         increase is fee and none of it belongs to the depositors. A decrease is netted against
   *         the fee that has not been paid out yet, so that a dip of the ERC4626 share price
   *         cannot turn depositor principal into fee when the price recovers. The stored balance
   *         is updated at the same time, so that a repeated call within the same transaction
   *         cannot accrue the same increase twice.
   */
  function _accrueFee() internal {
    uint256 balance = currentBalance();
    uint256 stored = storedBalance();
    uint256 fee = pendingFee();
    if (balance > stored) {
      setUint256(_PENDING_FEE_SLOT, fee + (balance - stored));
    } else if (stored > balance && fee > 0) {
      uint256 loss = stored - balance;
      setUint256(_PENDING_FEE_SLOT, fee > loss ? fee - loss : 0);
    }
    setUint256(_STORED_SUPPLIED_SLOT, balance);
  }

  function feeFloor() public view virtual returns (uint256) {
    return 1e3;
  }

  /**
   * @notice Processes any pending fees, redeems the fee amount, and forwards it to the fee recipients.
   */
  function _handleFee() internal {
    _accrueFee();
    if (!sell()) {
      // fee liquidation can be disabled for a possible simplified and rapid exit
      emit ProfitsNotCollected(sell(), false);
      return;
    }
    uint256 fee = pendingFee();
    if (fee > feeFloor()) {
      address _underlying = underlying();
      uint256 availableBalance = IERC20(_underlying).balanceOf(address(this));
      if (availableBalance < fee) {
        _redeemMaximum(fee - availableBalance);
      }
      fee = Math.min(fee, IERC20(_underlying).balanceOf(address(this)));
      if (fee <= 100) {
        // not enough to hand over to the reward forwarder, keep it pending
        return;
      }
      _notifyFee(_underlying, fee);
      setUint256(_PENDING_FEE_SLOT, pendingFee() - fee);
    }
  }

  /**
   * @notice Forwards the full amount to the fee recipients, split between profit sharing, platform
   *         and strategist in the proportions configured in the controller. This differs from
   *         `_notifyProfitInRewardToken`, which would only take `totalFeeNumerator` of the amount
   *         and leave the rest in the strategy (which for an inactive vault would end up with the
   *         depositors instead of being charged as fee).
   * @param _token Address of the token to be sent as fee.
   * @param _amount Amount of `_token` to be sent as fee.
   */
  function _notifyFee(address _token, uint256 _amount) internal {
    uint256 _totalFeeNumerator = totalFeeNumerator();
    uint256 strategistFee;
    uint256 platformFee;
    uint256 profitSharingFee;
    if (_totalFeeNumerator == 0) {
      // fees are switched off in the controller, the yield still is not for the depositors
      profitSharingFee = _amount;
    } else {
      strategistFee = _amount * strategistFeeNumerator() / _totalFeeNumerator;
      platformFee = _amount * platformFeeNumerator() / _totalFeeNumerator;
      // the remainder goes to profit sharing, so that the full amount is distributed
      profitSharingFee = _amount - strategistFee - platformFee;
    }

    address strategyFeeRecipient = strategist();
    address platformFeeRecipient = IController(controller()).governance();

    emit ProfitLogInReward(_token, _amount, profitSharingFee, block.timestamp);
    emit PlatformFeeLogInReward(platformFeeRecipient, _token, _amount, platformFee, block.timestamp);
    emit StrategistFeeLogInReward(strategyFeeRecipient, _token, _amount, strategistFee, block.timestamp);

    address rewardForwarder = IController(controller()).rewardForwarder();
    IERC20(_token).safeApprove(rewardForwarder, 0);
    IERC20(_token).safeApprove(rewardForwarder, _amount);

    IRewardForwarder(rewardForwarder).notifyFee(
      _token,
      profitSharingFee,
      strategistFee,
      platformFee
    );
  }

  /**
   * @notice Determines if a token is unsalvageable (i.e., cannot be removed from the strategy).
   * @param token Address of the token.
   * @return Boolean indicating if the token is unsalvageable.
   */
  function unsalvagableTokens(address token) public view returns (bool) {
    return (token == underlying() || token == fToken());
  }

  /**
   * @notice Invests the entire balance of underlying tokens into the ERC4626 vault.
   */
  function _investAllUnderlying() internal onlyNotPausedInvesting {
    address _underlying = underlying();
    uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
    // a deposit cap on the ERC4626 vault should not block the fee collection, the rest just
    // stays in the strategy and is still accounted for the depositors
    uint256 toSupply = Math.min(underlyingBalance, IERC4626(fToken()).maxDeposit(address(this)));
    if (toSupply > 1e3) {
      _supply(toSupply);
    }
  }

  /**
   * @notice Withdraws all assets from the strategy and transfers them to the vault. Fees that
   *         could not be paid out are kept in the strategy, they do not belong to the depositors.
   */
  function withdrawAllToVault() public restricted {
    _handleFee();
    address _underlying = underlying();
    _redeemAll();
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    uint256 fee = pendingFee();
    if (balance > fee) {
      IERC20(_underlying).safeTransfer(vault(), balance - fee);
    }
    _updateStoredBalance();
  }

  /**
   * @notice Exits the strategy by redeeming all assets and pauses further investments.
   */
  function emergencyExit() external onlyGovernance {
    _accrueFee();
    _redeemAllMaximum();
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
   * @notice Enables or disables the fee liquidation. With the fee liquidation disabled the yield is
   *         still accrued as fee, it is just not forwarded, so that the strategy can be exited even
   *         when the liquidation of the underlying would fail.
   * @param _sell Whether accrued fees should be forwarded to the fee recipients.
   */
  function setSell(bool _sell) public onlyGovernance {
    _setSell(_sell);
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
    uint256 toRedeem = amountUnderlying - balance;
    _redeem(toRedeem);
    balance = IERC20(_underlying).balanceOf(address(this));
    IERC20(_underlying).safeTransfer(vault(), Math.min(amountUnderlying, balance));
    balance = IERC20(_underlying).balanceOf(address(this));
    if (balance > 1e3 && !pausedInvesting()) {
      _investAllUnderlying();
    }
    _updateStoredBalance();
  }

  /**
   * @notice Collects the yield as fee and reinvests the idle underlying.
   */
  function doHardWork() public restricted {
    _handleFee();
    if (!pausedInvesting()) {
      _investAllUnderlying();
    }
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
   * @notice Returns the total balance of underlying assets that belongs to the vault depositors,
   *         which excludes the fees that have been accrued but not paid out yet.
   * @return Total balance of underlying assets.
   */
  function investedUnderlyingBalance() public view returns (uint256) {
    uint256 total = IERC20(underlying()).balanceOf(address(this)) + storedBalance();
    uint256 fee = pendingFee();
    return total > fee ? total - fee : 0;
  }

  /**
   * @notice Supplies a specified amount of underlying tokens to the ERC4626 vault.
   * @param amount Amount of tokens to supply.
   */
  function _supply(uint256 amount) internal {
    if (amount == 0) {
      return;
    }
    address _underlying = underlying();
    address _fToken = fToken();
    IERC20(_underlying).safeApprove(_fToken, 0);
    IERC20(_underlying).safeApprove(_fToken, amount);
    IERC4626(_fToken).deposit(amount, address(this));
  }

  /**
   * @notice Redeems a specified amount of underlying tokens from the ERC4626 vault. Reverts when
   *         the ERC4626 vault cannot serve the full amount: this is used on the paths where the
   *         Harvest vault has already burned the shares of a withdrawing depositor, so delivering
   *         less than requested would hand their funds to the remaining depositors.
   * @param amountUnderlying Amount of underlying tokens to redeem.
   */
  function _redeem(uint256 amountUnderlying) internal {
    if (amountUnderlying == 0) {
      return;
    }
    IERC4626(fToken()).withdraw(amountUnderlying, address(this), address(this));
  }

  /**
   * @notice Redeems as much of a specified amount of underlying tokens as the ERC4626 vault allows.
   *         Only used for the fee, which stays pending when it cannot be taken out right now.
   * @param amountUnderlying Amount of underlying tokens to redeem.
   */
  function _redeemMaximum(uint256 amountUnderlying) internal {
    if (amountUnderlying == 0) {
      return;
    }
    address _fToken = fToken();
    uint256 toWithdraw = Math.min(amountUnderlying, IERC4626(_fToken).maxWithdraw(address(this)));
    if (toWithdraw > 0) {
      IERC4626(_fToken).withdraw(toWithdraw, address(this), address(this));
    }
  }

  /**
   * @notice Redeems the whole position from the ERC4626 vault. Reverts when the ERC4626 vault
   *         cannot serve it, so that a depositor withdrawing the whole vault does not end up with
   *         only the liquid part while all of their shares are burned.
   */
  function _redeemAll() internal {
    address _fToken = fToken();
    uint256 shares = IERC20(_fToken).balanceOf(address(this));
    if (shares > 0) {
      IERC4626(_fToken).redeem(shares, address(this), address(this));
    }
  }

  /**
   * @notice Redeems as much of the position as the ERC4626 vault allows. Only used by
   *         `emergencyExit`, which does not pay out any depositor, so a partial exit is safe:
   *         what stays in the ERC4626 vault is still accounted for in the stored balance.
   */
  function _redeemAllMaximum() internal {
    address _fToken = fToken();
    uint256 shares = IERC20(_fToken).balanceOf(address(this));
    if (shares == 0) {
      return;
    }
    try IERC4626(_fToken).redeem(shares, address(this), address(this)) returns (uint256) {
      return;
    } catch {
      // the ERC4626 vault cannot serve the full position right now, take out what it allows
      uint256 redeemable = Math.min(shares, IERC4626(_fToken).maxRedeem(address(this)));
      if (redeemable > 0) {
        IERC4626(_fToken).redeem(redeemable, address(this), address(this));
      }
    }
  }

  /**
   * @notice Sets the address of the fToken.
   * @param _target Address of the fToken.
   */
  function _setFToken (address _target) internal {
    setAddress(_FTOKEN_SLOT, _target);
  }

  /**
   * @notice Returns the address of the fToken.
   * @return Address of the fToken.
   */
  function fToken() public view returns (address) {
    return getAddress(_FTOKEN_SLOT);
  }

  /**
   * @notice Finalizes the upgrade of the strategy.
   */
  function finalizeUpgrade() external virtual onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}
