// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {LowLevelCall} from "lib/openzeppelin-contracts/contracts/utils/LowLevelCall.sol";
import {Memory} from "lib/openzeppelin-contracts/contracts/utils/Memory.sol";

contract BaseAssetToVaultWrapperHelper {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    function _deposit(
        IERC4626 vaultWrapper,
        address underlyingVault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver
    ) internal returns (uint256) {
        uint256 underlyingVaultShares = _depositInUnderlyingVault(underlyingVault, asset, from, amount, address(this));
        return
            _depositIntoERC4626Vault(
                vaultWrapper, IERC20(underlyingVault), address(this), underlyingVaultShares, receiver
            );
    }

    /// @dev for aave wrappers, override this function
    function _depositInUnderlyingVault(
        address underlyingVault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver
    ) internal virtual returns (uint256) {
        return _depositIntoERC4626Vault(IERC4626(underlyingVault), asset, from, amount, receiver);
    }

    function _depositIntoERC4626Vault(IERC4626 vault, IERC20 asset, address from, uint256 amount, address receiver)
        internal
        returns (uint256)
    {
        if (from != address(this)) asset.safeTransferFrom(from, address(this), amount);

        try vault.deposit(amount, receiver) returns (uint256 shares) {
            return shares;
        } catch {
            // If deposit fails, it may have been because of lack of approval
            asset.forceApprove(address(vault), type(uint256).max);
            return vault.deposit(amount, receiver);
        }
    }

    function _redeem(IERC4626 vaultWrapper, address underlyingVault, address from, uint256 amount, address receiver)
        internal
        returns (uint256)
    {
        uint256 underlyingVaultShares = _redeemFromERC4626Vault(vaultWrapper, from, amount, address(this));
        return _redeemFromUnderlyingVault(address(underlyingVault), address(this), underlyingVaultShares, receiver);
    }

    /// @dev for aave wrapper, override this function
    function _redeemFromUnderlyingVault(address underlyingVault, address from, uint256 amount, address receiver)
        internal
        virtual
        returns (uint256)
    {
        return _redeemFromERC4626Vault(IERC4626(underlyingVault), from, amount, receiver);
    }

    /// @dev if from!=address(this) then they should have approve address(this) for amount of vault wrapper asset
    function _redeemFromERC4626Vault(IERC4626 vault, address from, uint256 amount, address receiver)
        internal
        returns (uint256)
    {
        return vault.redeem(amount, receiver, from);
    }

    function _mint(
        IERC4626 vaultWrapper,
        address underlyingVault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver
    ) internal returns (uint256 assetAmount) {
        uint256 underlyingSharesNeeded = vaultWrapper.previewMint(amount);
        assetAmount = _mintInUnderlyingVault(underlyingVault, asset, from, underlyingSharesNeeded, address(this));
        _mintERC4626VaultShares(vaultWrapper, IERC20(underlyingVault), address(this), amount, receiver);
    }

    function _mintInUnderlyingVault(address vault, IERC20 asset, address from, uint256 amount, address receiver)
        internal
        virtual
        returns (uint256)
    {
        return _mintERC4626VaultShares(IERC4626(vault), asset, from, amount, receiver);
    }

    function _mintERC4626VaultShares(IERC4626 vault, IERC20 asset, address from, uint256 amount, address receiver)
        internal
        returns (uint256)
    {
        if (from != address(this)) asset.safeTransferFrom(from, address(this), vault.previewMint(amount));

        try vault.mint(amount, receiver) returns (uint256 shares) {
            return shares;
        } catch {
            // If mint fails, it may have been because of lack of approval
            asset.forceApprove(address(vault), type(uint256).max);
            return vault.mint(amount, receiver);
        }
    }

    function _withdraw(IERC4626 vaultWrapper, address underlyingVault, address from, uint256 amount, address receiver)
        internal
        returns (uint256 shares)
    {
        uint256 underlyingVaultSharesToWithdraw = vaultWrapper.previewWithdraw(amount);
        shares = _withdrawFromERC4626Vault(vaultWrapper, from, amount, address(this));
        return _withdrawFromUnderlyingVault(underlyingVault, address(this), underlyingVaultSharesToWithdraw, receiver);
    }

    function _withdrawFromUnderlyingVault(address underlyingVault, address from, uint256 amount, address receiver)
        internal
        virtual
        returns (uint256)
    {
        return _withdrawFromERC4626Vault(IERC4626(underlyingVault), from, amount, receiver);
    }

    function _withdrawFromERC4626Vault(IERC4626 vault, address from, uint256 amount, address receiver)
        internal
        returns (uint256)
    {
        return vault.withdraw(amount, receiver, from);
    }

    function _getUnderlyingVault(IERC4626 vaultWrapper) internal view returns (IERC4626 underlyingVault) {
        Memory.Pointer ptr = Memory.getFreeMemoryPointer();
        (bool success, bytes32 underlyingVaultAddress,) =
            LowLevelCall.staticcallReturn64Bytes(address(vaultWrapper), abi.encodeCall(IERC4626.asset, ()));
        Memory.setFreeMemoryPointer(ptr);

        return (success && LowLevelCall.returnDataSize() >= 32
                && uint160(uint256(underlyingVaultAddress)) <= type(uint160).max)
            ? IERC4626(address(uint160(uint256(underlyingVaultAddress))))
            : IERC4626(address(0));
    }
}
