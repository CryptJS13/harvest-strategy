// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IERC4626.sol";
import "../../base/interface/stakeDao/IStakeVault.sol";
import "../../base/interface/stakeDao/IAccountant.sol";
import "../../base/interface/curve/ICurveDeposit_2token.sol";
import "../../base/interface/curve/ICurveDeposit_3token.sol";
import "../../base/interface/curve/ICurveDeposit_3token_meta.sol";
import "../../base/interface/curve/ICurveDeposit_4token.sol";
import "../../base/interface/curve/ICurveDeposit_4token_meta.sol";
import "../../base/interface/curve/ICurveDeposit_ng.sol";
import "../../base/interface/weth/IWETH.sol";

import "hardhat/console.sol";

contract StakeDaoStrategy is BaseUpgradeableStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant weth =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant multiSigAddr =
        address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _DEPOSIT_TOKEN_SLOT =
        0x219270253dbc530471c88a9e7c321b36afda219583431e7b6c386d2d46e70c86;
    bytes32 internal constant _DEPOSIT_ARRAY_POSITION_SLOT =
        0xb7c50ef998211fff3420379d0bf5b8dfb0cee909d1b7d9e517f311c104675b09;
    bytes32 internal constant _CURVE_DEPOSIT_SLOT =
        0xb306bb7adebd5a22f5e4cdf1efa00bc5f62d4f5554ef9d62c1b16327cd3ab5f9;
    bytes32 internal constant _NTOKENS_SLOT =
        0xbb60b35bae256d3c1378ff05e8d7bee588cd800739c720a107471dfa218f74c1;
    bytes32 internal constant _METAPOOL_SLOT =
        0x567ad8b67c826974a167f1a361acbef5639a3e7e02e99edbc648a84b0923d5b7;

    address[] public rewardTokens;

    constructor() BaseUpgradeableStrategy() {
        assert(
            _DEPOSIT_TOKEN_SLOT ==
                bytes32(
                    uint256(keccak256("eip1967.strategyStorage.depositToken")) -
                        1
                )
        );
        assert(
            _DEPOSIT_ARRAY_POSITION_SLOT ==
                bytes32(
                    uint256(
                        keccak256(
                            "eip1967.strategyStorage.depositArrayPosition"
                        )
                    ) - 1
                )
        );
        assert(
            _CURVE_DEPOSIT_SLOT ==
                bytes32(
                    uint256(keccak256("eip1967.strategyStorage.curveDeposit")) -
                        1
                )
        );
        assert(
            _NTOKENS_SLOT ==
                bytes32(
                    uint256(keccak256("eip1967.strategyStorage.nTokens")) - 1
                )
        );
        assert(
            _METAPOOL_SLOT ==
                bytes32(
                    uint256(keccak256("eip1967.strategyStorage.metaPool")) - 1
                )
        );
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _rewardPool,
        address _depositToken,
        uint256 _depositArrayPosition,
        address _curveDeposit,
        uint256 _nTokens,
        bool _metaPool
    ) public initializer {
        BaseUpgradeableStrategy.initialize(
            _storage,
            _underlying,
            _vault,
            _rewardPool,
            weth,
            multiSigAddr
        );

        address _lpt = IERC4626(_rewardPool).asset();
        require(_lpt == underlying(), "Pool Info does not match underlying");
        require(
            _depositArrayPosition < _nTokens,
            "Deposit array position out of bounds"
        );
        require(1 < _nTokens && _nTokens < 5, "_nTokens should be 2, 3 or 4");
        _setDepositArrayPosition(_depositArrayPosition);
        _setDepositToken(_depositToken);
        _setCurveDeposit(_curveDeposit);
        _setNTokens(_nTokens);
        _setMetaPool(_metaPool);
    }

    function depositArbCheck() public pure returns (bool) {
        return true;
    }

    function rewardPoolBalance() internal view returns (uint256 bal) {
        bal = IERC20(rewardPool()).balanceOf(address(this));
    }

    function exitRewardPool() internal {
        uint256 stakedBalance = rewardPoolBalance();
        if (stakedBalance != 0) {
            IERC4626(rewardPool()).redeem(stakedBalance, address(this), address(this));
        }
    }

    function partialWithdrawalRewardPool(uint256 amount) internal {
        IERC4626(rewardPool()).redeem(amount, address(this), address(this)); //don't claim rewards at this point
    }

    function emergencyExitRewardPool() internal {
        uint256 stakedBalance = rewardPoolBalance();
        if (stakedBalance != 0) {
            IERC4626(rewardPool()).redeem(stakedBalance, address(this), address(this)); //don't claim rewards
        }
    }

    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == rewardToken() || token == underlying());
    }

    function enterRewardPool() internal {
        address _underlying = underlying();
        address _rewardPool = rewardPool();
        uint256 entireBalance = IERC20(_underlying).balanceOf(address(this));
        IERC20(_underlying).safeApprove(_rewardPool, 0);
        IERC20(_underlying).safeApprove(_rewardPool, entireBalance);
        IERC4626(_rewardPool).deposit(entireBalance, address(this));
    }

    /*
     *   In case there are some issues discovered about the pool or underlying asset
     *   Governance can exit the pool properly
     *   The function is only used for emergency to exit the pool
     */
    function emergencyExit() public onlyGovernance {
        emergencyExitRewardPool();
        _setPausedInvesting(true);
    }

    /*
     *   Resumes the ability to invest into the underlying reward pools
     */

    function continueInvesting() public onlyGovernance {
        _setPausedInvesting(false);
    }

    function addRewardToken(address _token) public onlyGovernance {
        rewardTokens.push(_token);
    }

    // We assume that all the tradings can be done on Sushiswap
    function _liquidateReward() internal {
        if (!sell()) {
            // Profits can be disabled for possible simplified and rapoolId exit
            emit ProfitsNotCollected(sell(), false);
            return;
        }

        address _rewardToken = rewardToken();
        address _universalLiquidator = universalLiquidator();
        address _depositToken = depositToken();

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));

            if (balance == 0 || token == _rewardToken) {
                continue;
            }

            IERC20(token).safeApprove(_universalLiquidator, 0);
            IERC20(token).safeApprove(_universalLiquidator, balance);
            IUniversalLiquidator(_universalLiquidator).swap(
                token,
                _rewardToken,
                balance,
                1,
                address(this)
            );
        }

        uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
        if (rewardBalance <= 1e13) {
            return;
        }
        _notifyProfitInRewardToken(_rewardToken, rewardBalance);
        uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(
            address(this)
        );

        if (remainingRewardBalance == 0) {
            return;
        }

        if (_depositToken != _rewardToken) {
            IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
            IERC20(_rewardToken).safeApprove(
                _universalLiquidator,
                remainingRewardBalance
            );
            IUniversalLiquidator(_universalLiquidator).swap(
                _rewardToken,
                _depositToken,
                remainingRewardBalance,
                1,
                address(this)
            );
        }

        uint256 tokenBalance = IERC20(_depositToken).balanceOf(address(this));
        if (tokenBalance > 0) {
            depositCurve();
        }
    }

    function depositCurve() internal {
        address _depositToken = depositToken();
        address _curveDeposit = curveDeposit();

        uint256 tokenBalance = IERC20(_depositToken).balanceOf(address(this));

        if (_depositToken != weth) {
            IERC20(_depositToken).safeApprove(_curveDeposit, 1);
            if (tokenBalance > 1) {
                IERC20(_depositToken).safeIncreaseAllowance(
                    _curveDeposit,
                    tokenBalance - 1
                );
            }
        }

        uint256 minimum = 1;
        uint256 _nTokens = nTokens();
        if (metaPool()) {
            uint256[] memory depositArray = new uint256[](_nTokens);
            depositArray[depositArrayPosition()] = tokenBalance;
            if (_depositToken == weth) {
                IWETH(weth).withdraw(tokenBalance);
                ICurveDeposit_ng(_curveDeposit).add_liquidity{
                    value: tokenBalance
                }(depositArray, minimum);
            } else {
                ICurveDeposit_ng(_curveDeposit).add_liquidity(
                    depositArray,
                    minimum
                );
            }
        } else if (_nTokens == 2) {
            uint256[2] memory depositArray;
            depositArray[depositArrayPosition()] = tokenBalance;
            if (_depositToken == weth) {
                IWETH(weth).withdraw(tokenBalance);
                ICurveDeposit_2token(_curveDeposit).add_liquidity{
                    value: tokenBalance
                }(depositArray, minimum);
            } else {
                ICurveDeposit_2token(_curveDeposit).add_liquidity(
                    depositArray,
                    minimum
                );
            }
        } else if (_nTokens == 3) {
            uint256[3] memory depositArray;
            depositArray[depositArrayPosition()] = tokenBalance;
            ICurveDeposit_3token(_curveDeposit).add_liquidity(
                depositArray,
                minimum
            );
        } else if (_nTokens == 4) {
            uint256[4] memory depositArray;
            depositArray[depositArrayPosition()] = tokenBalance;
            ICurveDeposit_4token(_curveDeposit).add_liquidity(
                depositArray,
                minimum
            );
        }
    }

    /*
     *   Stakes everything the strategy holds into the reward pool
     */
    function investAllUnderlying() internal onlyNotPausedInvesting {
        // this check is needed, because most of the SNX reward pools will revert if
        // you try to stake(0).
        if (IERC20(underlying()).balanceOf(address(this)) > 0) {
            enterRewardPool();
        }
    }

    /*
     *   Withdraws all the asset to the vault
     */
    function withdrawAllToVault() public restricted {
        address _underlying = underlying();
        if (address(rewardPool()) != address(0)) {
            exitRewardPool();
        }
        _liquidateReward();
        IERC20(_underlying).safeTransfer(
            vault(),
            IERC20(_underlying).balanceOf(address(this))
        );
    }

    /*
     *   Withdraws all the asset to the vault
     */
    function withdrawToVault(uint256 amount) public restricted {
        address _underlying = underlying();
        // Typically there wouldn't be any amount here
        // however, it is possible because of the emergencyExit
        uint256 entireBalance = IERC20(_underlying).balanceOf(address(this));

        if (amount > entireBalance) {
            // While we have the check above, we still using SafeMath below
            // for the peace of mind (in case something gets changed in between)
            uint256 needToWithdraw = amount.sub(entireBalance);
            uint256 toWithdraw = Math.min(rewardPoolBalance(), needToWithdraw);
            partialWithdrawalRewardPool(toWithdraw);
        }
        IERC20(_underlying).safeTransfer(vault(), amount);
    }

    /*
     *   Note that we currently do not have a mechanism here to include the
     *   amount of reward that is accrued.
     */
    function investedUnderlyingBalance() external view returns (uint256) {
        return
            rewardPoolBalance().add(
                IERC20(underlying()).balanceOf(address(this))
            );
    }

    /*
     *   Governance or Controller can claim coins that are somehow transferred into the contract
     *   Note that they cannot come in take away coins that are used and defined in the strategy itself
     */
    function salvage(
        address recipient,
        address token,
        uint256 amount
    ) external onlyControllerOrGovernance {
        // To make sure that governance cannot come in and take away the coins
        require(
            !unsalvagableTokens(token),
            "token is defined as not salvagable"
        );
        IERC20(token).safeTransfer(recipient, amount);
    }

    function _claimRewards() internal {
        address _rewardPool = rewardPool();
        address accountant = IStakeVault(_rewardPool).ACCOUNTANT();
        address gauge = IStakeVault(_rewardPool).gauge();
        bytes memory emptyBytes = new bytes(0);
        address[] memory addresses = new address[](1);
        bytes[] memory bytesArray = new bytes[](1);
        addresses[0] = gauge;
        bytesArray[0] = emptyBytes;
        try IAccountant(accountant).claim(addresses, bytesArray) {
        } catch {
        }
    }

    /*
     *   Get the reward, sell it in exchange for underlying, invest what you got.
     *   It's not much, but it's honest work.
     *
     *   Note that although `onlyNotPausedInvesting` is not added here,
     *   calling `investAllUnderlying()` affectively blocks the usage of `doHardWork`
     *   when the investing is being paused by governance.
     */
    function doHardWork() external onlyNotPausedInvesting restricted {
        _claimRewards();
        _liquidateReward();
        investAllUnderlying();
    }

    /**
     * Can completely disable claiming UNI rewards and selling. Good for emergency withdraw in the
     * simplest possible way.
     */
    function setSell(bool s) public onlyGovernance {
        _setSell(s);
    }

    /**
     * Sets the minimum amount of CRV needed to trigger a sale.
     */
    function setSellFloor(uint256 floor) public onlyGovernance {
        _setSellFloor(floor);
    }

    function _setDepositToken(address _address) internal {
        setAddress(_DEPOSIT_TOKEN_SLOT, _address);
    }

    function depositToken() public view returns (address) {
        return getAddress(_DEPOSIT_TOKEN_SLOT);
    }

    function _setDepositArrayPosition(uint256 _value) internal {
        setUint256(_DEPOSIT_ARRAY_POSITION_SLOT, _value);
    }

    function depositArrayPosition() public view returns (uint256) {
        return getUint256(_DEPOSIT_ARRAY_POSITION_SLOT);
    }

    function _setCurveDeposit(address _address) internal {
        setAddress(_CURVE_DEPOSIT_SLOT, _address);
    }

    function curveDeposit() public view returns (address) {
        return getAddress(_CURVE_DEPOSIT_SLOT);
    }

    function _setNTokens(uint256 _value) internal {
        setUint256(_NTOKENS_SLOT, _value);
    }

    function nTokens() public view returns (uint256) {
        return getUint256(_NTOKENS_SLOT);
    }

    function _setMetaPool(bool _value) internal {
        setBoolean(_METAPOOL_SLOT, _value);
    }

    function metaPool() public view returns (bool) {
        return getBoolean(_METAPOOL_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        _finalizeUpgrade();
    }

    receive() external payable {}
}
