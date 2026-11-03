// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "../VaultV2.sol";
import "../interface/IInKindStrategy.sol";

/**
 * @title VaultV2InKind
 * @dev `VaultV2` extended with governance-gated in-kind redemptions.
 *
 * While enabled, a holder can burn their vault shares and receive their pro-rata slice of
 * the strategy's position tokens directly - the yield source's own ERC-20 shares - instead
 * of the underlying asset. That gives them an exit when the yield source has no redeemable
 * liquidity, alongside the normal withdrawal path, which keeps working throughout.
 *
 * The payout is a proportional split of the tokens actually held, so it never depends on
 * the vault's cached share price. It does depend on the cached price NOT being stale in
 * the other direction: minting at a stale price and immediately redeeming the true
 * pro-rata slice would capture unaccrued yield from the holders who stay. So while the
 * switch is on, every deposit and withdrawal syncs the strategy first and the ERC-4626
 * views quote at that same synced rate, so previews match execution exactly.
 *
 * This is the plain-`VaultV2` flavour, for vaults that use neither the withdrawal hook nor
 * the deposit cap. It is a drop-in implementation for an existing proxy: the switch lives
 * in its own hashed slot, is off by default, and every inherited entrypoint is unchanged
 * while it is off. Swapping the parent to `HookVaultV2` is all that a vault which does use
 * those needs.
 */
contract VaultV2InKind is VaultV2 {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    /// @dev keccak256("eip1967.vaultStorage.redeemInKindEnabled") - 1. The same slot the
    /// plain {VaultV2InKind} uses, so a vault can move between the two flavours.
    bytes32 internal constant _REDEEM_IN_KIND_ENABLED_SLOT = 0xa1c4a46e26d435a0ab545346c100c3d90a738cc204528b23378616049e546b9f;

    event RedeemInKind(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 shares,
        uint256 assetsOut,
        uint256 poolSharesOut
    );
    event RedeemInKindEnabled(bool enabled);

    constructor() {
        assert(_REDEEM_IN_KIND_ENABLED_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.redeemInKindEnabled")) - 1));
    }

    /**
     * @notice Whether in-kind redemptions are currently enabled.
     */
    function redeemInKindEnabled() public view returns (bool) {
        return getBoolean(_REDEEM_IN_KIND_ENABLED_SLOT);
    }

    /**
     * @notice Enables or disables in-kind redemptions. While enabled the strategy must
     * implement {IInKindStrategy}, because deposits and withdrawals sync it first.
     * @param _enabled New state of the in-kind redemption switch.
     */
    function setRedeemInKindEnabled(bool _enabled) external onlyGovernance {
        setBoolean(_REDEEM_IN_KIND_ENABLED_SLOT, _enabled);
        emit RedeemInKindEnabled(_enabled);
    }

    /**
     * @notice Burns `_owner`'s shares and pays `_receiver` their pro-rata slice of what the
     * vault holds: the strategy's position tokens, plus a pro-rata part of any underlying
     * sitting idle in the vault.
     * @param _shares Number of vault shares to redeem.
     * @param _receiver Address receiving the position tokens and underlying.
     * @param _owner Address whose vault shares are burned.
     * @return assetsOut Underlying transferred (pro-rata share of the vault's idle balance).
     * @return poolSharesOut Position tokens transferred.
     */
    function redeemInKind(
        uint256 _shares,
        address _receiver,
        address _owner
    ) public nonReentrant defense whenStrategyDefined returns (uint256 assetsOut, uint256 poolSharesOut) {
        require(redeemInKindEnabled(), "In-kind redemptions not enabled");
        require(_shares > 0, "shares must be greater than 0");
        require(_receiver != address(0), "receiver must be defined");
        uint256 totalSupplyBefore = totalSupply();
        require(totalSupplyBefore > 0, "Vault has no shares");

        if (msg.sender != _owner) {
            uint256 currentAllowance = allowance(_owner, msg.sender);
            if (currentAllowance != type(uint256).max) {
                require(currentAllowance >= _shares, "ERC20: transfer amount exceeds allowance");
                _approve(_owner, msg.sender, currentAllowance - _shares);
            }
        }
        _burn(_owner, _shares);

        assetsOut = underlyingBalanceInVault().mul(_shares).div(totalSupplyBefore);
        poolSharesOut = IInKindStrategy(strategy()).withdrawInKind(_shares, totalSupplyBefore, _receiver);
        require(assetsOut > 0 || poolSharesOut > 0, "nothing to redeem");
        if (assetsOut > 0) {
            IERC20Upgradeable(underlying()).safeTransfer(_receiver, assetsOut);
        }

        emit RedeemInKind(msg.sender, _receiver, _owner, _shares, assetsOut, poolSharesOut);
    }

    /**
     * @notice Estimates the payout of {redeemInKind} for a given number of vault shares.
     * @param _shares Number of vault shares to redeem.
     * @return assetsOut Estimated underlying payout.
     * @return poolSharesOut Estimated position-token payout.
     */
    function previewRedeemInKind(uint256 _shares) public view returns (uint256 assetsOut, uint256 poolSharesOut) {
        uint256 supply = totalSupply();
        if (_shares == 0 || supply == 0 || strategy() == address(0)) {
            return (0, 0);
        }
        assetsOut = underlyingBalanceInVault().mul(_shares).div(supply);
        poolSharesOut = IInKindStrategy(strategy()).previewWithdrawInKind(_shares, supply);
    }

    /**
     * @notice The position token paid out by {redeemInKind}.
     */
    function inKindToken() public view returns (address) {
        return IInKindStrategy(strategy()).rewardPool();
    }

    /**
     * @dev Syncs the strategy's cached balance while in-kind redemptions are enabled, so
     * deposits and withdrawals price at the live rate. A no-op while the switch is off,
     * which is what keeps this a drop-in for a vault whose strategy has no hooks.
     */
    function _syncStrategy() internal {
        address _strategy = strategy();
        if (redeemInKindEnabled() && _strategy != address(0)) {
            IInKindStrategy(_strategy).syncBalance();
        }
    }

    function _deposit(uint256 amount, address sender, address beneficiary) internal virtual override returns (uint256) {
        _syncStrategy();
        return super._deposit(amount, sender, beneficiary);
    }

    function _withdraw(uint256 numberOfShares, address receiver, address owner) internal virtual override returns (uint256) {
        _syncStrategy();
        return super._withdraw(numberOfShares, receiver, owner);
    }

    /**
     * @notice Total assets under management. While in-kind redemptions are enabled this
     * quotes at the live (synced) strategy balance, so previews match execution - which
     * syncs before it prices.
     * @return Total assets in the vault.
     */
    function totalAssets() public view virtual override returns (uint256) {
        address _strategy = strategy();
        if (redeemInKindEnabled() && _strategy != address(0)) {
            return underlyingBalanceInVault().add(IInKindStrategy(_strategy).syncedInvestedUnderlyingBalance());
        }
        return underlyingBalanceWithInvestment();
    }
}
