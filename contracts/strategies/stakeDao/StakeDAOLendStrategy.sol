// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/IERC4626.sol";
import "../../base/interface/stakeDao/IStakeVault.sol";
import "../../base/interface/stakeDao/IAccountant.sol";

contract StakeDAOLendStrategy is BaseUpgradeableStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

    bytes32 internal constant _LENDING_VAULT_SLOT =
        0x8b86aeb97224511570debab032f96aaf5e60e935a719498681731f3bbfad60da;
    bytes32 internal constant _STORED_SUPPLIED_SLOT =
        0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
    bytes32 internal constant _PENDING_FEE_SLOT =
        0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

    address[] public rewardTokens;

    constructor() BaseUpgradeableStrategy() {
        assert(_LENDING_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.lendingVault")) - 1));
        assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
        assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _lendingVault,
        address _rewardPool,
        address _rewardToken
    ) public initializer {
        BaseUpgradeableStrategy.initialize(
            _storage,
            _underlying,
            _vault,
            _rewardPool,
            _rewardToken,
            harvestMSIG
        );

        require(IERC4626(_lendingVault).asset() == _underlying, "Underlying mismatch");
        require(IERC4626(_rewardPool).asset() == _lendingVault, "StakeDAO asset must be lending vault LP");

        _setLendingVault(_lendingVault);
    }

    function depositArbCheck() public pure returns (bool) {
        return true;
    }

    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == rewardToken() || token == underlying());
    }

    // ==================== Reward Pool (StakeDAO) ====================

    function _rewardPoolBalance() internal view returns (uint256 bal) {
        bal = IERC20(rewardPool()).balanceOf(address(this));
    }

    function _exitRewardPool() internal {
        uint256 stakedBalance = _rewardPoolBalance();
        if (stakedBalance != 0) {
            IERC4626(rewardPool()).redeem(stakedBalance, address(this), address(this));
        }
    }

    function _partialWithdrawalRewardPool(uint256 amount) internal {
        IERC4626(rewardPool()).withdraw(amount, address(this), address(this));
    }

    function _enterRewardPool() internal {
        address _lendingVault = lendingVault();
        address _rewardPool = rewardPool();
        uint256 entireBalance = IERC20(_lendingVault).balanceOf(address(this));
        IERC20(_lendingVault).safeApprove(_rewardPool, 0);
        IERC20(_lendingVault).safeApprove(_rewardPool, entireBalance);
        IERC4626(_rewardPool).deposit(entireBalance, address(this));
    }

    // ==================== Balance & Fee (from ConvexLend) ====================

    function currentBalance() public view returns (uint256) {
        address _lendingVault = lendingVault();
        uint256 balance = IERC20(_lendingVault).balanceOf(address(this)).add(_rewardPoolBalance());
        return IERC4626(_lendingVault).previewRedeem(balance);
    }

    function storedBalance() public view returns (uint256) {
        return getUint256(_STORED_SUPPLIED_SLOT);
    }

    function _updateStoredBalance() internal {
        setUint256(_STORED_SUPPLIED_SLOT, currentBalance());
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

    // ==================== Investment ====================

    function _investAllUnderlying() internal onlyNotPausedInvesting {
        address _underlying = underlying();
        uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
        if (underlyingBalance > 1e1) {
            _supply(underlyingBalance);
        }
        _enterRewardPool();
    }

    // ==================== Withdrawals ====================

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
        _redeem(toRedeem);
        balance = IERC20(_underlying).balanceOf(address(this));
        IERC20(_underlying).safeTransfer(vault(), Math.min(amountUnderlying, balance));
        balance = IERC20(_underlying).balanceOf(address(this));
        if (balance > 1e1) {
            _investAllUnderlying();
        }
        _updateStoredBalance();
    }

    // ==================== Hard Work ====================

    function doHardWork() public restricted {
        _claimRewards();
        _liquidateRewards();
        _investAllUnderlying();
        _updateStoredBalance();
    }

    // ==================== Rewards (from StakeDaoStrategy) ====================

    function _claimRewards() internal {
        address accountant = IStakeVault(rewardPool()).ACCOUNTANT();
        address gaugeAddr = IStakeVault(rewardPool()).gauge();
        address[] memory addresses = new address[](1);
        bytes[] memory bytesArray = new bytes[](1);
        addresses[0] = gaugeAddr;
        bytesArray[0] = new bytes(0);
        try IAccountant(accountant).claim(addresses, bytesArray) {} catch {}
    }

    function _liquidateRewards() internal {
        if (!sell()) {
            emit ProfitsNotCollected(sell(), false);
            return;
        }
        _handleFee();

        address _rewardToken = rewardToken();
        address _universalLiquidator = universalLiquidator();

        for (uint256 i = 0; i < rewardTokens.length; i++) {
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
        if (_underlying != _rewardToken) {
            IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
            IERC20(_rewardToken).safeApprove(_universalLiquidator, remainingRewardBalance);
            IUniversalLiquidator(_universalLiquidator).swap(
                _rewardToken,
                _underlying,
                remainingRewardBalance,
                1,
                address(this)
            );
        }
    }

    // ==================== Lending Vault (from ConvexLend) ====================

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

    function _redeemAll() internal {
        _exitRewardPool();
        address _lendingVault = lendingVault();
        uint256 lpBalance = IERC20(_lendingVault).balanceOf(address(this));
        if (lpBalance > 0) {
            IERC4626(_lendingVault).redeem(lpBalance, address(this), address(this));
        }
    }

    // ==================== View & Admin ====================

    function investedUnderlyingBalance() public view returns (uint256) {
        uint256 total = IERC20(underlying()).balanceOf(address(this)).add(storedBalance());
        uint256 fee = pendingFee();
        // Clamped rather than subtracted outright: this is read by every vault entrypoint, so
        // an underflow here would take deposits, withdrawals and the share price down with it.
        return total > fee ? total.sub(fee) : 0;
    }

    function salvage(address recipient, address token, uint256 amount) public onlyGovernance {
        require(!unsalvagableTokens(token), "token is defined as not salvagable");
        IERC20(token).safeTransfer(recipient, amount);
    }

    function addRewardToken(address _token) public onlyGovernance {
        rewardTokens.push(_token);
    }

    function setSell(bool s) public onlyGovernance {
        _setSell(s);
    }

    function setSellFloor(uint256 floor) public onlyGovernance {
        _setSellFloor(floor);
    }

    // ==================== Getters ====================

    function _setLendingVault(address _target) internal {
        setAddress(_LENDING_VAULT_SLOT, _target);
    }

    function lendingVault() public view returns (address) {
        return getAddress(_LENDING_VAULT_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        _finalizeUpgrade();
    }

    receive() external payable {}
}
