// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {
    IERC20,
    ERC20,
    Math,
    ERC4626,
    IERC4626
} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

import {BaseVaultWrapper} from "src/VaultWrappers/Base/BaseVaultWrapper.sol";

/**
 * @notice This vault wrapper is intended for use with lending protocol vaults where the underlying vault share price monotonically increases.
 * @dev If the underlying vault share price drops, this vault may become insolvent. In cases of bad debt socialization within the lending protocol vaults, the share price can decrease.
 *      It is recommended to have an insurance fund capable of burning tokens to restore solvency if needed.
 *      No harvest operations will occur until the vault regains solvency.
 */
contract ERC4626VaultWrapper is BaseVaultWrapper {
    constructor() BaseVaultWrapper() {}

    function totalAssets() public view override returns (uint256) {
        return IERC20(getUnderlyingVault()).balanceOf(address(this));
    }

    function underlyingVault() public view returns (IERC4626) {
        return IERC4626(getUnderlyingVault());
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return underlyingVault().previewWithdraw(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return underlyingVault().previewMint(assets);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return underlyingVault().previewRedeem(assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return underlyingVault().previewDeposit(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return underlyingVault().convertToAssets(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return underlyingVault().convertToShares(shares);
    }

    function maxDeposit(address) public view override returns (uint256) {
        return underlyingVault().maxMint(address(this));
    }

    function maxMint(address) public view override returns (uint256) {
        return underlyingVault().maxDeposit(address(this));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(underlyingVault().maxWithdraw(address(this)), balanceOf(owner));
    }

    function _maxWithdrawableAssets() internal view override returns (uint256) {
        return underlyingVault().maxWithdraw(address(this));
    }
}
