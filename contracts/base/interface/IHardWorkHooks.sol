// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

/**
 * @title IHardWorkHooks
 * @dev Optional strategy interface for strategies that cannot deposit into their yield
 * source inside a user's withdrawal transaction.
 *
 * `compoundOnWithdraw` exists so that an exiting user is credited the interest accrued
 * since the last hard work, rather than leaving it to the remaining holders. The vault
 * achieves that by calling `IStrategy.doHardWork()` before it prices the withdrawal.
 *
 * For most strategies that is fine. But `doHardWork()` also ends by depositing idle
 * underlying into the yield source, and the vault then redeems from that same yield
 * source later in the same transaction. Some yield sources forbid that pairing - a
 * redemption delay, a withdrawal queue, or a same-block deposit/withdraw restriction -
 * and the withdrawal reverts.
 *
 * A strategy implementing this interface offers a withdrawal-safe subset: accrue fees,
 * liquidate rewards and refresh the stored balance - everything that credits the exiting
 * user - while leaving the deposit to the next `doHardWork()`.
 *
 * `doHardWork()` itself is unchanged and still deposits, so keepers need no
 * reconfiguration and the deposit path is unaffected.
 */
interface IHardWorkHooks {
    /**
     * @notice Whether this strategy implements the hard work hook below.
     * @dev Vaults staticcall this to decide whether to use the hook or fall back to
     * `IStrategy.doHardWork()`. Implementations must return true; a strategy that does
     * not implement the interface simply has no such function and the staticcall fails
     * or returns nothing, which the vault treats as "not supported".
     * @return True if `doHardWorkOnWithdraw` is implemented.
     */
    function supportsHardWorkHooks() external view returns (bool);

    /**
     * @notice Hard work to run inside a user's withdrawal transaction.
     * @dev Must credit accrued interest the same way `doHardWork()` would, but must not
     * deposit into the underlying yield source, because the vault may redeem from it
     * later in the same transaction.
     */
    function doHardWorkOnWithdraw() external;
}
