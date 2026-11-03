// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../../base/interface/IUniversalLiquidator.sol";
import "../../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../../base/interface/morpho/IMorphoVault.sol";

contract MorphoVaultV2Strategy is BaseUpgradeableStrategy {

  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _MORPHO_VAULT_SLOT = 0xf5b51c17c9e35d4327e4aa5b82628726ecdd06e6cb73d4658ac1e871f3879ea3;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

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
    return strategistFeeNumerator() + platformFeeNumerator() + profitSharingNumerator();
  }

  function pendingFee() public view returns (uint256) {
    return getUint256(_PENDING_FEE_SLOT);
  }

  function _accrueFee() internal {
    uint256 fee;
    if (currentSupplied() > storedSupplied()) {
      uint256 balanceIncrease = currentSupplied() - storedSupplied();
      fee = balanceIncrease * totalFeeNumerator() / feeDenominator();
    }
    setUint256(_PENDING_FEE_SLOT, pendingFee() + fee);
  }

  function feeFloor() public view virtual returns (uint256) {
    return 1e3;
  }

  function _handleFee() internal {
    _accrueFee();
    uint256 fee = pendingFee();
    if (fee > feeFloor()) {
      _redeem(fee);
      address _underlying = underlying();
      fee = Math.min(fee, IERC20(_underlying).balanceOf(address(this)));
      uint256 balanceIncrease = fee * feeDenominator() / totalFeeNumerator();
      _notifyProfitInRewardToken(_underlying, balanceIncrease);
      setUint256(_PENDING_FEE_SLOT, pendingFee() - fee);
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
    _liquidateRewards();
    _redeemMaximum();
    // Keep back whatever fee `_handleFee` could not pay out - it is below the dust floor,
    // or the yield source refused the redemption. Handing it to the vault along with
    // everything else would leave `pendingFee` with nothing behind it, and
    // `investedUnderlyingBalance()` would then report less than zero.
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    uint256 fee = pendingFee();
    if (balance > fee) {
      IERC20(_underlying).safeTransfer(vault(), balance - fee);
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
    uint256 toRedeem = amountUnderlying - balance;
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
      if (token == _rewardToken) continue;
      _syncRewardStream(token);
      uint256 toSell = _pullClaimable(token);
      if (toSell > 0){
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
  * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
  */
  function doHardWork() public restricted {
    _handleFee();
    _claimGeneralIncentives();
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
    uint256 total = IERC20(underlying()).balanceOf(address(this)) + storedSupplied();
    uint256 fee = pendingFee();
    // Clamped rather than subtracted outright: this is read by every vault entrypoint, so
    // an underflow here would take deposits, withdrawals and the share price down with it.
    return total > fee ? total - fee : 0;
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
    // The fee is deliberately left supplied: it doubles as the rounding margin that keeps
    // `withdraw` from asking the Morpho vault for more than the shares can cover.
    uint256 supplied = currentSupplied();
    uint256 fee = pendingFee();
    if (supplied > fee) {
      _redeem(supplied - fee);
    }
  }

  function _setMorphoVault (address _target) internal {
    setAddress(_MORPHO_VAULT_SLOT, _target);
  }

  function morphoVault() public view returns (address) {
    return getAddress(_MORPHO_VAULT_SLOT);
  }

  function finalizeUpgrade() external virtual onlyGovernance {
    _finalizeUpgrade();
  }

  function _setDistributionTime(address token, uint256 duration) internal {
    require(duration == 0 || duration > 10, "duration > 10 || 0");
    _stream[token].duration = duration;
  }

  function setDistributionTime(address token, uint256 duration) external onlyGovernance {
    _setDistributionTime(token, duration);
  }

  receive() external payable {}
}
