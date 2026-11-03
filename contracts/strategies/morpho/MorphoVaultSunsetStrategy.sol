// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IRewardPrePay.sol";
import "../../base/interface/morpho/IMorphoVault.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";

/**
 * @title MorphoVaultSunsetStrategy
 * @dev Upgrade target for a `MorphoVaultStrategyV2` whose Morpho vault position can no longer
 *      be redeemed and has been compensated in the underlying token, paid straight to the
 *      strategy. It finalises that recovery and winds the Harvest vault down:
 *
 *      - The Morpho vault shares are written off. Nothing here reads, redeems from or deposits
 *        into the Morpho vault. `investedUnderlyingBalance()` is the strategy's own underlying
 *        balance and nothing else, so the compensation - and anything that lands here later,
 *        like a further distribution - is all the vault's share price is based on.
 *      - Hard work only sells the reward tokens the strategy holds for the underlying, with
 *        the fees taken as usual on the way, and keeps the proceeds idle in the strategy.
 *      - Withdrawals are served from that idle balance, so every vault entrypoint keeps
 *        working whatever state the Morpho vault is in.
 *      - The vault takes no new deposits (`depositArbCheck` is false). The share price moves in
 *        steps, whenever something lands here, and an open door would let a newcomer step in
 *        front of the holders the next distribution is meant for.
 *      - The written-off shares no longer back anything the depositors own, so governance can
 *        salvage them like any other token that is not the underlying.
 *
 *      The storage layout is the one of `MorphoVaultStrategyV2`: same base, `rewardTokens` in
 *      the same slot, the four slots of the V2 reward drip reserved. The proxy's state carries
 *      over unchanged, and the V2 accounting of the Morpho position (`storedSupplied` and
 *      `pendingFee`) is zeroed when the upgrade is finalised.
 */
contract MorphoVaultSunsetStrategy is BaseUpgradeableStrategy {

  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here,
  // the same ones MorphoVaultStrategyV2 uses
  bytes32 internal constant _MORPHO_VAULT_SLOT = 0xf5b51c17c9e35d4327e4aa5b82628726ecdd06e6cb73d4658ac1e871f3879ea3;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;
  bytes32 internal constant _PRE_PAY_SLOT = 0xe180f2889f5981f1caaf808c7622138447eebb1465f259a8b806e6f390c14884;

  // Regular storage, laid out exactly as in MorphoVaultStrategyV2.
  address[] public rewardTokens;
  // The four mappings of the V2 reward drip (rewardBalanceLast, lastRewardTime, rewardPerSec,
  // distributionTime) took the next four slots. The sunset sells every reward in full on each
  // hard work, so the drip is gone; the slots stay reserved.
  uint256[4] private __legacyRewardDrip;

  event MorphoPositionWrittenOff(address indexed morphoVault, uint256 storedSupplied, uint256 pendingFee);
  /// @notice This reward token could not be sold; the others were, and it stays here for a later try or a salvage.
  event RewardSaleSkipped(address indexed token);
  /// @notice The reward sale on the way out failed; the exit went ahead without it.
  event RewardLiquidationSkipped();

  modifier onlyRewardPrePayOrGovernance() {
    require(msg.sender == morphoPrePay() || (msg.sender == governance()),
      "only rewardPrePay can call this");
    _;
  }

  constructor() BaseUpgradeableStrategy() {
    assert(_MORPHO_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.morphoVault")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
    assert(_PRE_PAY_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.prePay")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _morphoVault,
    address _rewardToken,
    address _morphoPrePay
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
    setAddress(_MORPHO_VAULT_SLOT, _morphoVault);
    setAddress(_PRE_PAY_SLOT, _morphoPrePay);
  }

  /**
  * The vault requires this to be true to mint shares, so `false` closes the vault to deposits
  * while leaving every withdrawal path untouched. This is a sunset.
  */
  function depositArbCheck() public pure returns (bool) {
    return false;
  }

  /**
  * The Morpho vault shares are written off, so they are not the depositors' any more and
  * governance may move them, e.g. to redeem them should the Morpho vault ever free up.
  */
  function unsalvagableTokens(address token) public view returns (bool) {
    return token == underlying();
  }

  /**
  * Returns the current balance: the underlying held here, nothing else. The shares in the
  * Morpho vault are ignored completely.
  */
  function investedUnderlyingBalance() public view returns (uint256) {
    return IERC20(underlying()).balanceOf(address(this));
  }

  /**
  * Sells the rewards for the underlying and keeps the proceeds here. Nothing is supplied
  * anywhere.
  */
  function doHardWork() public restricted {
    _claimGeneralIncentives();
    _liquidateRewards();
  }

  function withdrawToVault(uint256 amountUnderlying) public restricted {
    if (amountUnderlying == 0) {
      return;
    }
    IERC20(underlying()).safeTransfer(vault(), amountUnderlying);
  }

  /**
  * Transfers everything to the vault. Selling the rewards on the way out is a courtesy and
  * must never be able to block the exit itself (the last holder leaving, or a strategy switch).
  */
  function withdrawAllToVault() public restricted {
    try this.liquidateRewards() {
    } catch {
      emit RewardLiquidationSkipped();
    }
    address _underlying = underlying();
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    if (balance > 0) {
      IERC20(_underlying).safeTransfer(vault(), balance);
    }
  }

  /**
  * External only so that `withdrawAllToVault` can wrap the reward sale in a try/catch.
  */
  function liquidateRewards() external {
    require(msg.sender == address(this), "only self");
    _liquidateRewards();
  }

  function addRewardToken(address _token) public onlyGovernance {
    rewardTokens.push(_token);
  }

  /**
  * External only so that `_liquidateRewards` can wrap each reward token's sale in a try/catch.
  */
  function sellReward(address token) external {
    require(msg.sender == address(this), "only self");
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance == 0) {
      return;
    }
    address _rewardToken = rewardToken();
    address _universalLiquidator = universalLiquidator();
    IERC20(token).safeApprove(_universalLiquidator, 0);
    IERC20(token).safeApprove(_universalLiquidator, balance);
    IUniversalLiquidator(_universalLiquidator).swap(token, _rewardToken, balance, 1, address(this));
  }

  function _liquidateRewards() internal {
    address _rewardToken = rewardToken();
    address _universalLiquidator = universalLiquidator();
    for (uint256 i; i < rewardTokens.length; i++) {
      address token = rewardTokens[i];
      if (token == _rewardToken) {
        continue;
      }
      // One reward that cannot be sold - a dust balance the liquidator refuses, a route it has
      // lost - must not stop the others from being sold.
      try this.sellReward(token) {
      } catch {
        emit RewardSaleSkipped(token);
      }
    }
    uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
    _notifyProfitInRewardToken(_rewardToken, rewardBalance);
    uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));

    if (remainingRewardBalance <= 1e3) {
      return;
    }

    address _underlying = underlying();
    if (_underlying != _rewardToken) {
      IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
      IERC20(_rewardToken).safeApprove(_universalLiquidator, remainingRewardBalance);
      IUniversalLiquidator(_universalLiquidator).swap(_rewardToken, _underlying, remainingRewardBalance, 1, address(this));
    }
  }

  function morphoClaim(
    address distr,
    bytes calldata txData
  ) external onlyRewardPrePayOrGovernance {
    address _morphoPrePay = morphoPrePay();
    address morpho = IRewardPrePay(_morphoPrePay).MORPHO();
    uint256 balanceBefore = IERC20(morpho).balanceOf(address(this));
    (bool success,) = distr.call(txData);
    require(success, "Claim failed");
    uint256 claimed = IERC20(morpho).balanceOf(address(this)) - balanceBefore;
    IERC20(morpho).safeTransfer(_morphoPrePay, claimed);
  }

  /**
  * Salvages a token.
  */
  function salvage(address recipient, address token, uint256 amount) public onlyGovernance {
    // To make sure that governance cannot come in and take away the coins
    require(!unsalvagableTokens(token), "token is defined as not salvagable");
    IERC20(token).safeTransfer(recipient, amount);
  }

  function morphoVault() public view returns (address) {
    return getAddress(_MORPHO_VAULT_SLOT);
  }

  function setMorphoPrePay (address _target) public onlyGovernance {
    setAddress(_PRE_PAY_SLOT, _target);
  }

  function morphoPrePay() public view returns (address) {
    return getAddress(_PRE_PAY_SLOT);
  }

  /**
  * Runs on the proxy right after it switches to this implementation (and on any later direct
  * call by governance): resets the upgrade schedule and writes the Morpho position off.
  */
  function finalizeUpgrade() external virtual onlyGovernance {
    _finalizeUpgrade();
    _writeOffMorphoPosition();
  }

  /**
  * Zeroes the V2 accounting of the Morpho position. Nothing here reads these slots; zeroing
  * them records the write-off on chain and leaves nothing behind for a later implementation
  * that would read `storedSupplied`. It does not disarm the shares themselves: an
  * implementation that prices them off the Morpho vault, as V2 does, would bring the position
  * straight back. Salvage the shares out before any such upgrade.
  */
  function _writeOffMorphoPosition() internal {
    uint256 storedSupplied = getUint256(_STORED_SUPPLIED_SLOT);
    uint256 pendingFee = getUint256(_PENDING_FEE_SLOT);
    if (storedSupplied == 0 && pendingFee == 0) {
      return;
    }
    setUint256(_STORED_SUPPLIED_SLOT, 0);
    setUint256(_PENDING_FEE_SLOT, 0);
    emit MorphoPositionWrittenOff(morphoVault(), storedSupplied, pendingFee);
  }

  receive() external payable {}
}
