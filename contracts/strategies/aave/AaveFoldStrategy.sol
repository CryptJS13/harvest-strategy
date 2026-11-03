// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/balancer/IBVault.sol";
import "../../base/interface/aave/IAToken.sol";
import "../../base/interface/aave/IVariableDebtToken.sol";
import "../../base/interface/aave/IPool.sol";
import "../../base/interface/aave/IAaveIncentivesController.sol";

contract AaveFoldStrategy is BaseUpgradeableStrategy {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xF49440C1F012d041802b25A73e5B0B9166a75c02);
  address public constant bVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _ATOKEN_SLOT = 0x8cdee58637b787efaa2d78bb1da1e053a2c91e61640b32339bfbba65c00abd68;
  bytes32 internal constant _DEBT_TOKEN_SLOT = 0x29e482e0e21cdcc43d1f0a48ba975f14078bf56d1ca40ed3f48e655ac06df8cb;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;
  bytes32 internal constant _COLLATERALFACTORNUMERATOR_SLOT = 0x129eccdfbcf3761d8e2f66393221fa8277b7623ad13ed7693a0025435931c64a;
  bytes32 internal constant _FACTORDENOMINATOR_SLOT = 0x4e92df66cc717205e8df80bec55fc1429f703d590a2d456b97b74f0008b4a3ee;
  bytes32 internal constant _BORROWTARGETFACTORNUMERATOR_SLOT = 0xa65533f4b41f3786d877c8fdd4ae6d27ada84e1d9c62ea3aca309e9aa03af1cd;
  bytes32 internal constant _FOLD_SLOT = 0x1841be4c16015a744c9fbf595f7c6b32d40278c16c1fc7cf2de88c6348de44ba;

  uint256 public suppliedInUnderlying;
  uint256 public borrowedInUnderlying;

  bool internal makingFlashDeposit;
  bool internal makingFlashWithdrawal;

  // this would be reset on each upgrade
  address[] public rewardTokens;
  mapping(address => bool) public isAToken;

  constructor() BaseUpgradeableStrategy() {
    assert(_ATOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.aToken")) - 1));
    assert(_DEBT_TOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.debtToken")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
    assert(_COLLATERALFACTORNUMERATOR_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.collateralFactorNumerator")) - 1));
    assert(_FACTORDENOMINATOR_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.factorDenominator")) - 1));
    assert(_BORROWTARGETFACTORNUMERATOR_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.borrowTargetFactorNumerator")) - 1));
    assert(_FOLD_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.fold")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _aToken,
    address _debtToken,
    address _rewardToken,
    uint256 _borrowTargetFactorNumerator,
    uint256 _collateralFactorNumerator,
    uint256 _factorDenominator,
    bool _fold
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _aToken,
      _rewardToken,
      harvestMSIG
    );

    require(IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() == _underlying, "Underlying mismatch");
    require(IVariableDebtToken(_debtToken).UNDERLYING_ASSET_ADDRESS() == _underlying, "Underlying mismatch");
    _setAToken(_aToken);
    _setDebtToken(_debtToken);

    require(_collateralFactorNumerator < _factorDenominator, "Numerator should be smaller than denominator");
    require(_borrowTargetFactorNumerator < _collateralFactorNumerator, "Target should be lower than limit");
    _setFactorDenominator(_factorDenominator);
    setUint256(_COLLATERALFACTORNUMERATOR_SLOT, _collateralFactorNumerator);
    setUint256(_BORROWTARGETFACTORNUMERATOR_SLOT, _borrowTargetFactorNumerator);
    setBoolean(_FOLD_SLOT, _fold);
  }

  modifier updateSupplyInTheEnd() {
    _;
    // amount we supplied
    suppliedInUnderlying = IAToken(aToken()).balanceOf(address(this));
    // amount we borrowed
    borrowedInUnderlying = IVariableDebtToken(debtToken()).balanceOf(address(this));
  }

  function currentBalance() public view returns (uint256) {
    return IAToken(aToken()).balanceOf(address(this)).sub(IVariableDebtToken(debtToken()).balanceOf(address(this)));
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
    return 1e2;
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
    return (token == underlying() || token == aToken());
  }

  function _investAllUnderlying() internal onlyNotPausedInvesting updateSupplyInTheEnd {
    address _underlying = underlying();
    uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
    if (underlyingBalance > 0) {
      _supply(underlyingBalance);
    }
    if (fold()) {
      _depositWithFlashloan();
    }
  }

  function withdrawAllToVault() public restricted updateSupplyInTheEnd {
    address _underlying = underlying();
    _withdrawMaximum(true);
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

  function emergencyExit() external onlyGovernance updateSupplyInTheEnd {
    _withdrawMaximum(false);
    _setPausedInvesting(true);
    _updateStoredBalance();
  }

  function _withdrawMaximum(bool claim) internal {
    if (claim) {
      _handleFee();
      uint256 aTokenAmount = _claimReward();
      _liquidateReward(aTokenAmount);
    } else {
      _accrueFee();
    }
    _redeemMaximumWithFlashloan();
  }

  function continueInvesting() public onlyGovernance {
    _setPausedInvesting(false);
  }

  function withdrawToVault(uint256 amountUnderlying) public restricted updateSupplyInTheEnd {
    _accrueFee();
    address _underlying = underlying();
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    if (amountUnderlying <= balance) {
      IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
      return;
    }
    uint256 toRedeem = amountUnderlying.sub(balance);
    // get some of the underlying
    _redeemPartial(toRedeem);
    // transfer the amount requested (or the amount we have) back to vault()
    IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
    balance = IERC20(_underlying).balanceOf(address(this));
    if (balance > 0) {
      _investAllUnderlying();
    }
    _updateStoredBalance();
  }

  function _redeemPartial(uint256 amountUnderlying) internal {
    address _underlying = underlying();
    uint256 balanceBefore = IERC20(_underlying).balanceOf(address(this));
    _redeemWithFlashloan(
      amountUnderlying,
      fold()? borrowTargetFactorNumerator():0
    );
    uint256 balanceAfter = IERC20(_underlying).balanceOf(address(this));
    require(balanceAfter.sub(balanceBefore) >= amountUnderlying, "Unable to withdraw the entire amountUnderlying");
  }

  function doHardWork() public restricted {
    _handleFee();
    uint256 aTokenAmount = _claimReward();
    _liquidateReward(aTokenAmount);
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

  function _claimReward() internal returns (uint256 aTokenAmount){
    address _aToken = aToken();
    address incentivesController = IAToken(_aToken).getIncentivesController();
    address[] memory assets = new address[](2);
    assets[0] = _aToken;
    assets[1] = debtToken();
    uint256 balanceBefore = IERC20(_aToken).balanceOf(address(this));
    IAaveIncentivesController(incentivesController).claimAllRewards(assets, address(this));
    aTokenAmount = IERC20(_aToken).balanceOf(address(this)).sub(balanceBefore);
  }

  function _liquidateReward(uint256 aTokenAmount) internal {
    if (!sell()) {
      // Profits can be disabled for possible simplified and rapid exit
      emit ProfitsNotCollected(sell(), false);
      return;
    }
    address _rewardToken = rewardToken();
    address _universalLiquidator = universalLiquidator();
    for(uint256 i = 0; i < rewardTokens.length; i++){
      address token = rewardTokens[i];
      uint256 balance;
      if (token == aToken()) {
        balance = aTokenAmount;
        _redeem(balance);
        token = underlying();
      } else {
        if (isAToken[token]) {
          balance = IERC20(token).balanceOf(address(this));
          if (balance > 0) {
            address _pool = IAToken(token).POOL();
            token = IAToken(token).UNDERLYING_ASSET_ADDRESS();
            IPool(_pool).withdraw(token, balance, address(this));
          }
        } else {
          balance = IERC20(token).balanceOf(address(this));
        }
      }

      if (balance == 0) {
        continue;
      }

      if (token != _rewardToken){
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
  * Returns the current balance.
  */
  function investedUnderlyingBalance() public view returns (uint256) {
    uint256 total = IERC20(underlying()).balanceOf(address(this)).add(storedBalance());
    uint256 fee = pendingFee();
    // Clamped rather than subtracted outright: this is read by every vault entrypoint, so
    // an underflow here would take deposits, withdrawals and the share price down with it.
    return total > fee ? total.sub(fee) : 0;
  }

  function _supply(uint256 amountUnderlying) internal {
    if (amountUnderlying < 1e2){
      return;
    }
    address _underlying = underlying();
    address _pool = IAToken(aToken()).POOL();
    IERC20(_underlying).safeApprove(_pool, 0);
    IERC20(_underlying).safeApprove(_pool, amountUnderlying);
    IPool(_pool).supply(_underlying, amountUnderlying, address(this), 0);
  }

  function _borrow(uint256 amountUnderlying) internal {
    if (amountUnderlying == 0){
      return;
    }
    address _pool = IAToken(aToken()).POOL();
    IPool(_pool).borrow(underlying(), amountUnderlying, 2, 0, address(this));
  }

  function _redeem(uint256 amountUnderlying) internal {
    if (amountUnderlying == 0){
      return;
    }
    address _pool = IAToken(aToken()).POOL();
    IPool(_pool).withdraw(underlying(), amountUnderlying, address(this));
  }

  function _repay(uint256 amountUnderlying) internal {
    if (amountUnderlying == 0){
      return;
    }
    address _underlying = underlying();
    address _pool = IAToken(aToken()).POOL();
    IERC20(_underlying).safeApprove(_pool, 0);
    IERC20(_underlying).safeApprove(_pool, amountUnderlying);
    IPool(_pool).repay(_underlying, amountUnderlying, 2, address(this));
  }

  function _redeemMaximumWithFlashloan() internal {
    address _aToken = aToken();
    // amount we supplied
    uint256 supplied = IAToken(_aToken).balanceOf(address(this));
    // amount we borrowed
    uint256 borrowed = IVariableDebtToken(debtToken()).balanceOf(address(this));
    // The fee is deliberately left supplied, and the `+1` is the rounding margin that keeps
    // the redemption from asking for more than the position can cover. Clamped rather than
    // subtracted outright, so that a fee larger than the position cannot revert the exit.
    uint256 netBalance = supplied.sub(borrowed);
    uint256 fee = pendingFee().add(1);
    uint256 balance = netBalance > fee ? netBalance.sub(fee) : 0;

    _redeemWithFlashloan(balance, 0);
    supplied = IAToken(_aToken).balanceOf(address(this));
    if (supplied > pendingFee()) {
      _redeem(supplied.sub(pendingFee().add(1)));
    }
  }

  function _depositWithFlashloan() internal {
    uint _denom = factorDenominator();
    uint _borrowNum = borrowTargetFactorNumerator();
    // amount we supplied
    uint256 supplied = IAToken(aToken()).balanceOf(address(this));
    // amount we borrowed
    uint256 borrowed = IVariableDebtToken(debtToken()).balanceOf(address(this));
    uint256 balance = supplied.sub(borrowed);
    uint256 borrowTarget = balance.mul(_borrowNum).div(_denom.sub(_borrowNum));
    uint256 borrowDiff;
    if (borrowed > borrowTarget) {
      _redeemPartial(0);
      borrowDiff = 0;
    } else {
      borrowDiff = borrowTarget.sub(borrowed);
    }
    address _underlying = underlying();
    uint256 balancerBalance = IERC20(_underlying).balanceOf(bVault);

    if (borrowDiff > balancerBalance) {
      _depositNoFlash(supplied, borrowed, _denom, _borrowNum);
    } else {
      address[] memory tokens = new address[](1);
      uint256[] memory amounts = new uint256[](1);
      bytes memory userData = abi.encode(0);
      tokens[0] = _underlying;
      amounts[0] = borrowDiff;
      makingFlashDeposit = true;
      IBVault(bVault).flashLoan(address(this), tokens, amounts, userData);
      makingFlashDeposit = false;
    }
  }

  function _redeemWithFlashloan(uint256 amount, uint256 _borrowTargetFactorNumerator) internal {
    // amount we supplied
    uint256 supplied = IAToken(aToken()).balanceOf(address(this));
    // amount we borrowed
    uint256 borrowed = IVariableDebtToken(debtToken()).balanceOf(address(this));
    uint256 newBorrowTarget;
    {
        uint256 oldBalance = supplied.sub(borrowed);
        uint256 newBalance = oldBalance.sub(amount);
        newBorrowTarget = newBalance.mul(_borrowTargetFactorNumerator).div(factorDenominator().sub(_borrowTargetFactorNumerator));
    }
    uint256 borrowDiff;
    if (borrowed < newBorrowTarget) {
      borrowDiff = 0;
    } else {
      borrowDiff = borrowed.sub(newBorrowTarget);
    }
    address _underlying = underlying();
    uint256 balancerBalance = IERC20(_underlying).balanceOf(bVault);

    if (borrowDiff > balancerBalance) {
      _redeemNoFlash(amount, supplied, borrowed, factorDenominator(), _borrowTargetFactorNumerator);
    } else {
      address[] memory tokens = new address[](1);
      uint256[] memory amounts = new uint256[](1);
      bytes memory userData = abi.encode(0);
      tokens[0] = _underlying;
      amounts[0] = borrowDiff;
      makingFlashWithdrawal = true;
      IBVault(bVault).flashLoan(address(this), tokens, amounts, userData);
      makingFlashWithdrawal = false;
      _redeem(amount);
    }
  }

  function receiveFlashLoan(IERC20[] memory /*tokens*/, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory /*userData*/) external {
    require(msg.sender == bVault);
    require(!makingFlashDeposit || !makingFlashWithdrawal, "Only one can be true");
    require(makingFlashDeposit || makingFlashWithdrawal, "One has to be true");
    address _underlying = underlying();
    uint256 toRepay = amounts[0].add(feeAmounts[0]);
    if (makingFlashDeposit){
      _supply(amounts[0]);
      _borrow(toRepay);
    } else {
      uint256 borrowed = IVariableDebtToken(debtToken()).balanceOf(address(this));
      uint256 repaying = Math.min(amounts[0], borrowed);
      _repay(repaying);
      _redeem(toRepay);
    }
    IERC20(_underlying).safeTransfer(bVault, toRepay);
  }

  function _depositNoFlash(uint256 supplied, uint256 borrowed, uint256 _denom, uint256 _borrowNum) internal {
    address _underlying = underlying();
    uint256 balance = supplied.sub(borrowed);
    uint256 borrowTarget = balance.mul(_borrowNum).div(_denom.sub(_borrowNum));

    while (borrowed < borrowTarget) {
      uint256 wantBorrow = borrowTarget.sub(borrowed);
      uint256 maxBorrow = supplied.mul(collateralFactorNumerator()).div(_denom).sub(borrowed);
      _borrow(Math.min(wantBorrow, maxBorrow));
      uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
      if (underlyingBalance > 0) {
        _supply(underlyingBalance);
      }
      //update parameters
      borrowed = IVariableDebtToken(debtToken()).balanceOf(address(this));
      supplied = IAToken(aToken()).balanceOf(address(this));
    }
  }

  function _redeemNoFlash(uint256 amount, uint256 supplied, uint256 borrowed, uint256 _denom, uint256 _borrowNum) internal {
    address _underlying = underlying();
    uint256 newBorrowTarget;
    {
        uint256 oldBalance = supplied.sub(borrowed);
        uint256 newBalance = oldBalance.sub(amount);
        newBorrowTarget = newBalance.mul(_borrowNum).div(_denom.sub(_borrowNum));
    }
    while (borrowed > newBorrowTarget) {
      uint256 requiredCollateral = borrowed.mul(_denom).div(collateralFactorNumerator());
      uint256 toRepay = borrowed.sub(newBorrowTarget);
      // redeem just as much as needed to repay the loan
      // supplied - requiredCollateral = max redeemable, amount + repay = needed
      uint256 toRedeem = Math.min(supplied.sub(requiredCollateral), amount.add(toRepay));
      _redeem(toRedeem);
      // now we can repay our borrowed amount
      uint256 _underlyingBalance = IERC20(_underlying).balanceOf(address(this));
      _repay(Math.min(toRepay, _underlyingBalance));
      // update the parameters
      borrowed = IVariableDebtToken(debtToken()).balanceOf(address(this));
      supplied = IAToken(aToken()).balanceOf(address(this));
    }
    uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
    if (underlyingBalance < amount) {
      uint256 toRedeem = amount.sub(underlyingBalance);
      uint256 balance = supplied.sub(borrowed);
      // redeem the most we can redeem
      _redeem(Math.min(toRedeem, balance));
    }
  }

    // updating collateral factor
  // note 1: one should settle the loan first before calling this
  // note 2: collateralFactorDenominator is 1000, therefore, for 20%, you need 200
  function _setCollateralFactorNumerator(uint256 _numerator) public onlyGovernance {
    require(_numerator <= factorDenominator(), "Collateral factor cannot be this high");
    require(_numerator > borrowTargetFactorNumerator(), "Collateral factor should be higher than borrow target");
    setUint256(_COLLATERALFACTORNUMERATOR_SLOT, _numerator);
  }

  function collateralFactorNumerator() public view returns (uint256) {
    return getUint256(_COLLATERALFACTORNUMERATOR_SLOT);
  }

  function _setFactorDenominator(uint256 _denominator) internal {
    setUint256(_FACTORDENOMINATOR_SLOT, _denominator);
  }

  function factorDenominator() public view returns (uint256) {
    return getUint256(_FACTORDENOMINATOR_SLOT);
  }

  function setBorrowTargetFactorNumerator(uint256 _numerator) public onlyGovernance {
    require(_numerator < collateralFactorNumerator(), "Target should be lower than collateral limit");
    setUint256(_BORROWTARGETFACTORNUMERATOR_SLOT, _numerator);
  }

  function borrowTargetFactorNumerator() public view returns (uint256) {
    return getUint256(_BORROWTARGETFACTORNUMERATOR_SLOT);
  }

  function setFold (bool _fold) public onlyGovernance {
    setBoolean(_FOLD_SLOT, _fold);
  }

  function fold() public view returns (bool) {
    return getBoolean(_FOLD_SLOT);
  }

  function _setAToken (address _target) internal {
    setAddress(_ATOKEN_SLOT, _target);
  }

  function aToken() public view returns (address) {
    return getAddress(_ATOKEN_SLOT);
  }

  function _setDebtToken (address _target) internal {
    setAddress(_DEBT_TOKEN_SLOT, _target);
  }

  function debtToken() public view returns (address) {
    return getAddress(_DEBT_TOKEN_SLOT);
  }

  function finalizeUpgrade() external onlyGovernance updateSupplyInTheEnd {
    _finalizeUpgrade();
  }

  receive() external payable {}
}