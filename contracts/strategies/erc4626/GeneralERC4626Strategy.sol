// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/IERC4626.sol";
import "../../base/interface/IHardWorkHooks.sol";

/**
 * @title GeneralERC4626Strategy
 * @dev A strategy that invests underlying assets into an ERC4626 compliant vault, providing yield and rewards.
 */
contract GeneralERC4626Strategy is BaseUpgradeableStrategy, IHardWorkHooks {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  /// @notice Emitted when a fee redemption was refused by the vault and left pending.
  event FeeRedeemDeferred(uint256 amount);
  /// @notice Emitted when the vault refused a deposit and the underlying was left idle.
  event SupplyDeferred(uint256 amount);
  /// @notice Emitted when a holder was paid out in the yield source's own shares.
  event WithdrawInKind(address indexed receiver, uint256 shareNumerator, uint256 shareDenominator, uint256 poolSharesOut);

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  bytes32 internal constant _FTOKEN_SLOT = 0x462e4d44c9bae3e0ee3d71929710bef82ca7c929ce31980e75572ea415835b0e;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;
  bytes32 internal constant _LOSS_CARRY_SLOT = 0x41899daaeb9cc577a761309ed45b44d3e89e0a9eaa6cd4333a3ebb5fa844d157;

  // this would be reset on each upgrade
  address[] public rewardTokens;

  struct Stream {
    uint256 lastUpdate;     // last timestamp we updated unlocked accounting
    uint256 periodFinish;   // end of current stream period
    uint256 rate;          // tokens per second (truncated), in token's natural units

    uint256 accounted;     // how many tokens are reserved/managed by the stream (locked+unlocked-not-yet-sold)
    uint256 unlocked;      // unlocked amount accumulated since last sale (ready to sell)
    uint256 duration;      // distribution duration (seconds). 0 disables streaming (sell all)
  }

  mapping(address => Stream) internal _stream;

  constructor() BaseUpgradeableStrategy() {
    assert(_FTOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.fToken")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
    assert(_LOSS_CARRY_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.lossCarry")) - 1));
  }

  /**
   * @notice Initializes the strategy and verifies compatibility with the ERC4626 vault.
   * @param _storage Address of the storage contract.
   * @param _underlying Address of the underlying asset.
   * @param _vault Address of the vault.
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
    // Marked GROSS, with `convertToAssets`. Any exit fee the yield source charges is
    // deliberately left out of the share price and is instead borne by the user whose
    // withdrawal actually triggers a redemption - see `_redeem`. A withdrawal the vault
    // can serve from idle triggers none and pays none; that fee stays latent in the
    // position until someone does redeem.
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
   * @notice Value the position has lost and not yet earned back. No performance fee is
   * charged until it has.
   * @return The unrecovered loss, in underlying.
   */
  function lossCarry() public view returns (uint256) {
    return getUint256(_LOSS_CARRY_SLOT);
  }

  /**
   * @notice Accrues the performance fee on the gain since the last call, above the high
   * water mark.
   * @dev `storedBalance` cannot itself be the high water mark: it has to track the real
   * size of the position, which supplying and redeeming legitimately move. So a drop in
   * value is remembered separately in `lossCarry` and offsets later gains, and only what
   * is left is charged.
   *
   * Every caller runs this BEFORE it supplies or redeems in the same transaction, and
   * `_updateStoredBalance()` runs after, so the difference measured here is always a pure
   * change in value and never the strategy's own deposits or withdrawals.
   *
   * Without this, a dip resets the mark and depositors are charged the full fee for
   * earning their own loss back. These are actively managed vaults whose NAV does fall -
   * on a management-fee share mint, a rebalance, or a market-balance refresh - so over a
   * saw-toothing period the fee taken would otherwise run well past the intended share of
   * true net profit.
   */
  function _accrueFee() internal {
    uint256 balance = currentBalance();
    uint256 stored = storedBalance();

    if (balance < stored) {
      setUint256(_LOSS_CARRY_SLOT, lossCarry().add(stored.sub(balance)));
      return;
    }
    if (balance == stored) {
      return;
    }

    uint256 gain = balance.sub(stored);
    uint256 carry = lossCarry();
    if (carry > 0) {
      uint256 recovered = Math.min(carry, gain);
      setUint256(_LOSS_CARRY_SLOT, carry.sub(recovered));
      gain = gain.sub(recovered);
    }
    if (gain > 0) {
      setUint256(_PENDING_FEE_SLOT, pendingFee().add(gain.mul(totalFeeNumerator()).div(feeDenominator())));
    }
  }

  /**
   * @notice Smallest fee worth paying out. Below this it stays pending and is retried on
   * the next call, rather than spending gas forwarding dust.
   * @dev Virtual so a strategy on a low-decimal underlying can lower it.
   * @return The floor, in underlying.
   */
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
      address _underlying = underlying();
      uint256 availableBalance = IERC20(_underlying).balanceOf(address(this));
      if (availableBalance < fee) {
        address _fToken = fToken();
        uint256 redeemable = Math.min(
          fee.sub(availableBalance),
          IERC4626(_fToken).maxWithdraw(address(this))
        );
        if (redeemable > 0) {
          // The vault may refuse this redemption - a redemption delay, a withdrawal
          // queue, or not enough instantly available liquidity. Leaving the fee in
          // pendingFee and retrying on the next call is correct; reverting here would
          // block doHardWork() and withdrawAllToVault() for everyone.
          try IERC4626(_fToken).withdraw(redeemable, address(this), address(this)) returns (uint256) {
          } catch {
            emit FeeRedeemDeferred(redeemable);
          }
        }
      }
      fee = Math.min(fee, IERC20(_underlying).balanceOf(address(this)));
      if (fee == 0) {
        return;
      }
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
    return (token == rewardToken() || token == underlying() || token == fToken());
  }

  /**
   * @notice Invests the entire balance of underlying tokens into the lending pool.
   */
  function _investAllUnderlying() internal onlyNotPausedInvesting {
    address _underlying = underlying();
    uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
    // Only offer what the yield source says it will accept. These vaults run a total
    // deposit cap and `deposit` reverts outright once it is reached, which would take
    // `doHardWork()` down with it and stop the strategy earning on anything at all.
    // `maxDeposit` is only a quote - see `_supply` - so this is the cheap first line, not
    // the guarantee.
    // The quote is shaved by a tenth of a percent because it is optimistic: these vaults
    // accrue their management fee on the way in, which lifts total assets and shrinks the
    // remaining cap inside the very same transaction, so depositing exactly the quoted
    // headroom is rejected. The margin only ever binds when the strategy is actually up
    // against the cap - in the normal case the balance is far below it and this is a no-op.
    // Subtracting a thousandth rather than multiplying by 999: an uncapped vault reports
    // `type(uint256).max` here, and multiplying that overflows.
    uint256 headroom = IERC4626(fToken()).maxDeposit(address(this));
    uint256 toSupply = Math.min(underlyingBalance, headroom.sub(headroom.div(1000)));
    if (toSupply > 1e3) {
      _supply(toSupply);
    }
  }

  /**
   * @notice Withdraws all assets from the strategy and transfers to the vault.
   */
  function withdrawAllToVault() public restricted {
    _handleFee();
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
    // Any residue stays idle and is supplied by the next doHardWork(). Re-supplying it
    // here would deposit into the vault immediately after redeeming from it, which some
    // yield sources forbid.
    _updateStoredBalance();
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
      if (token == _rewardToken) continue;
      _syncRewardStream(token);
      uint256 toSell = _pullClaimable(token);
      if (toSell > 1e3) {
        IERC20(token).safeApprove(_universalLiquidator, 0);
        IERC20(token).safeApprove(_universalLiquidator, toSell);
        IUniversalLiquidator(_universalLiquidator).swap(token, _rewardToken, toSell, 1, address(this));
      }
    }
    uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
    _notifyProfitInRewardToken(_rewardToken, rewardBalance);
    uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));

    if (remainingRewardBalance <= 1e12) {
      return;
    }
  
    address _underlying = underlying();
    if (_underlying != _rewardToken) {
      IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
      IERC20(_rewardToken).safeApprove(_universalLiquidator, remainingRewardBalance);
      IUniversalLiquidator(_universalLiquidator).swap(_rewardToken, _underlying, remainingRewardBalance, 1, address(this));
    }
  }

  function distributionTime(address token) public view returns (uint256) {
    return _stream[token].duration;
  }

  function sellable(address token) public view returns (uint256) {
    Stream memory stream = _stream[token];
    if (stream.duration == 0) {
      return IERC20(token).balanceOf(address(this));
    }
    uint256 unlockedAccrued = stream.unlocked;
    uint256 last = stream.lastUpdate;
    if (last == 0) return unlockedAccrued;

    uint256 nowTs = block.timestamp;
    uint256 effEnd = Math.min(nowTs, stream.periodFinish);
    if (effEnd <= last) return unlockedAccrued;

    uint256 dt = effEnd - last;
    return unlockedAccrued + (dt * stream.rate);
  }

  function _accrueUnlocked(address token) internal {
    Stream storage stream = _stream[token];
    uint256 nowTs = block.timestamp;

    uint256 last = stream.lastUpdate;
    if (last == 0) {
      stream.lastUpdate = nowTs;
      return;
    }

    uint256 effEnd = Math.min(nowTs, uint256(stream.periodFinish));
    if (effEnd <= last) {
      return;
    }

    uint256 dt = effEnd - last;
    uint256 unlockedNow = dt * uint256(stream.rate);

    if (unlockedNow > 0) {
      stream.unlocked += unlockedNow;
    }

    stream.lastUpdate = effEnd;
  }

  function _syncRewardStream(address token) internal {
    Stream storage stream = _stream[token];
    uint256 nowTs = block.timestamp;

    // If streaming is disabled, we don't need to track anything.
    if (stream.duration == 0) {
      // keep accounting minimal: avoid stale accounted/unlocked causing confusion.
      stream.accounted = 0;
      stream.unlocked = 0;
      stream.rate = 0;
      stream.lastUpdate = nowTs;
      stream.periodFinish = nowTs;
      return;
    }

    _accrueUnlocked(token);

    uint256 bal = IERC20(token).balanceOf(address(this));
    uint256 accounted = stream.accounted;
    uint256 newlyArrived = (bal > accounted) ? (bal - accounted) : 0;

    if (newlyArrived == 0) {
      return;
    }

    uint256 duration = stream.duration;

    uint256 leftover = 0;
    if (nowTs < uint256(stream.periodFinish)) {
      uint256 remaining = uint256(stream.periodFinish) - nowTs;
      leftover = remaining * uint256(stream.rate);
    }

    uint256 totalToStream = newlyArrived + leftover;
    uint256 newRate = totalToStream / duration;

    stream.rate = newRate;
    stream.lastUpdate = nowTs;
    stream.periodFinish = nowTs + duration;

    // 4) Increase accounted by the newly arrived amount (we now manage it)
    stream.accounted = accounted + newlyArrived;
  }

  function _pullClaimable(address token) internal returns (uint256 amount) {
    Stream storage stream = _stream[token];

    if (stream.duration == 0) {
      amount = IERC20(token).balanceOf(address(this));
      return amount;
    }

    _accrueUnlocked(token);

    amount = stream.unlocked;
    if (amount == 0) return 0;

    uint256 bal = IERC20(token).balanceOf(address(this));
    amount = Math.min(amount, bal);

    stream.unlocked -= amount;

    if (stream.accounted >= amount) {
      stream.accounted -= amount;
    } else {
      // very defensive; should not happen unless token is weird (rebasing/fee-on-transfer)
      stream.accounted = 0;
    }
  }

  /**
   * @notice Executes the main strategy logic including reward liquidation and reinvestment.
   */
  function doHardWork() public restricted {
    _handleFee();
    _liquidateRewards();
    _investAllUnderlying();
    _updateStoredBalance();
  }

  /**
   * @notice Whether this strategy implements the optional hard work hooks.
   * @return Always true.
   */
  function supportsHardWorkHooks() external pure returns (bool) {
    return true;
  }

  /**
   * @notice Hard work run inside a user's withdrawal transaction by a hook-aware vault.
   * @dev Everything `doHardWork()` does to credit the exiting user - accrue the fee on
   * the interest earned since the last call, liquidate rewards into underlying, and
   * refresh `storedBalance` so `investedUnderlyingBalance()` reflects it - but without
   * `_investAllUnderlying()`. Supplying here would deposit into the fToken immediately
   * before the vault redeems from it, which the redemption delay forbids. Underlying
   * left idle is still counted by `investedUnderlyingBalance()` and is supplied by the
   * next `doHardWork()`.
   */
  function doHardWorkOnWithdraw() external restricted {
    _handleFee();
    _liquidateRewards();
    _updateStoredBalance();
  }

  // ========================= In-Kind Redemption =========================

  /**
   * @notice Transfers `_shareNumerator / _shareDenominator` of the strategy's position
   * tokens - net of the shares backing accrued fees - straight to `_receiver`.
   * @dev Called by an in-kind vault when a holder redeems in kind, so they can exit even
   * while the yield source has no redeemable liquidity. The fraction is the holder's share
   * of the vault's supply, so the payout is exactly proportional to the tokens actually
   * held and does not depend on any cached exchange rate.
   *
   * The shares backing `pendingFee` are carved out before the split, so an in-kind exit
   * cannot walk off with fees the strategy has not yet collected. `previewWithdraw` is the
   * right measure for that carve-out: it grosses up for any exit fee the yield source
   * charges, so what stays behind really is worth `pendingFee`.
   * @param _shareNumerator Numerator of the redeemed fraction (redeemed vault shares).
   * @param _shareDenominator Denominator of the fraction (vault supply before the burn).
   * @param _receiver Address receiving the position tokens.
   * @return poolSharesOut Amount of position tokens transferred.
   */
  function withdrawInKind(
    uint256 _shareNumerator,
    uint256 _shareDenominator,
    address _receiver
  ) external restricted returns (uint256 poolSharesOut) {
    require(_shareDenominator > 0, "denominator must be greater than 0");
    require(_shareNumerator <= _shareDenominator, "numerator must not exceed denominator");
    _accrueFee();
    address _fToken = fToken();
    uint256 balance = IERC20(_fToken).balanceOf(address(this));
    uint256 feeShares = IERC4626(_fToken).previewWithdraw(pendingFee());
    uint256 netBalance = balance > feeShares ? balance.sub(feeShares) : 0;
    poolSharesOut = netBalance.mul(_shareNumerator).div(_shareDenominator);
    if (poolSharesOut > 0) {
      IERC20(_fToken).safeTransfer(_receiver, poolSharesOut);
    }
    _updateStoredBalance();
    emit WithdrawInKind(_receiver, _shareNumerator, _shareDenominator, poolSharesOut);
  }

  /**
   * @notice Accrues the fee and refreshes the cached balance, so the vault's share price
   * reflects the yield source's live rate.
   * @dev Called by an in-kind vault before it prices a deposit or a withdrawal. Without it
   * a depositor could mint at a stale cached price and immediately redeem the true
   * pro-rata token slice, taking unaccrued yield from the holders who stay.
   */
  function syncBalance() external restricted {
    _accrueFee();
    _updateStoredBalance();
  }

  /**
   * @dev The pending fee as it would stand immediately after an accrual.
   * Mirrors {_accrueFee}, high water mark included: a gain first repays whatever
   * `lossCarry` is outstanding and only the excess is charged. Reading it without that
   * would overstate the fee and carve too many shares out of an in-kind payout.
   */
  function _simulatedPendingFee() internal view returns (uint256) {
    uint256 pending = pendingFee();
    uint256 balance = currentBalance();
    uint256 stored = storedBalance();
    if (balance <= stored) {
      return pending;
    }
    uint256 gain = balance.sub(stored);
    uint256 carry = lossCarry();
    if (carry >= gain) {
      return pending;
    }
    return pending.add(gain.sub(carry).mul(totalFeeNumerator()).div(feeDenominator()));
  }

  /**
   * @notice The invested balance as it would stand right after {syncBalance}, i.e. priced
   * off the yield source's live rate rather than the cached one.
   * @dev Used by an in-kind vault to quote deposits and withdrawals, so previews match the
   * synced rate execution actually uses.
   * @return Live invested underlying balance, net of the pending fee.
   */
  function syncedInvestedUnderlyingBalance() public view returns (uint256) {
    uint256 gross = IERC20(underlying()).balanceOf(address(this)).add(currentBalance());
    uint256 pending = _simulatedPendingFee();
    return gross > pending ? gross.sub(pending) : 0;
  }

  /**
   * @notice Estimates the position-token payout of {withdrawInKind}, including the fee
   * that would accrue at execution time.
   * @param _shareNumerator Numerator of the redeemed fraction.
   * @param _shareDenominator Denominator of the redeemed fraction.
   * @return Estimated amount of position tokens that would be transferred.
   */
  function previewWithdrawInKind(
    uint256 _shareNumerator,
    uint256 _shareDenominator
  ) public view returns (uint256) {
    if (_shareDenominator == 0) {
      return 0;
    }
    address _fToken = fToken();
    uint256 balance = IERC20(_fToken).balanceOf(address(this));
    uint256 feeShares = IERC4626(_fToken).previewWithdraw(_simulatedPendingFee());
    uint256 netBalance = balance > feeShares ? balance.sub(feeShares) : 0;
    return netBalance.mul(_shareNumerator).div(_shareDenominator);
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
    address _fToken = fToken();
    IERC20(_underlying).safeApprove(_fToken, 0);
    IERC20(_underlying).safeApprove(_fToken, amount);
    // The deposit is allowed to fail. `maxDeposit` is a quote taken before the call, and
    // these vaults accrue their management fee on the way in - which lifts total assets and
    // shrinks the remaining cap inside the very same transaction, so a deposit of exactly
    // the quoted headroom is rejected. A paused or restricted vault refuses in the same
    // way. None of that should be able to revert `doHardWork()` and every path that calls
    // it: the underlying simply stays idle, still counted by
    // `investedUnderlyingBalance()`, and the next hard work tries again.
    try IERC4626(_fToken).deposit(amount, address(this)) returns (uint256) {
    } catch {
      IERC20(_underlying).safeApprove(_fToken, 0);
      emit SupplyDeferred(amount);
    }
  }

  /**
   * @notice Redeems a specified amount of underlying tokens from the lending pool.
   * @param amountUnderlying Amount of underlying tokens to redeem.
   */
  function _redeem(uint256 amountUnderlying) internal {
    address _fToken = fToken();
    // Burn the shares worth `amountUnderlying` and take whatever the yield source pays for
    // them. With the position marked gross, that delivers `amountUnderlying` less the exit
    // fee, and `VaultV1._withdraw` hands the withdrawing user `min(entitlement, idle)` -
    // so the shortfall is exactly the fee and it lands on them alone.
    //
    // NOT `withdraw(assets)`, which delivers the full amount and burns the fee as EXTRA
    // shares on top: the position would fall by more than was paid out, the vault would
    // reprice the exit off the reduced total, and the fee would spread over every holder.
    // And not `previewWithdraw` either - grossing up would deliver the full entitlement
    // and push the fee onto the holders who stay.
    uint256 shares = Math.min(
      IERC4626(_fToken).convertToShares(amountUnderlying),
      IERC20(_fToken).balanceOf(address(this))
    );
    if (shares == 0) {
      return;
    }
    IERC4626(_fToken).redeem(shares, address(this), address(this));
  }

  /**
   * @notice Redeems all assets from the lending pool.
   */
  function _redeemAll() internal {
    address _fToken = fToken();
    if (IERC20(_fToken).balanceOf(address(this)) > 0) {
      IERC4626(_fToken).redeem(
        IERC20(_fToken).balanceOf(address(this)),
        address(this),
        address(this)
      );
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

  function _setDistributionTime(address token, uint256 duration) internal {
    require(duration == 0 || duration > 10, "duration > 10 || 0");
    _stream[token].duration = duration;
  }

  function setDistributionTime(address token, uint256 duration) external onlyGovernance {
    _setDistributionTime(token, duration);
  }


  /**
   * @notice Finalizes the upgrade of the strategy.
   */
  function finalizeUpgrade() external virtual onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}
