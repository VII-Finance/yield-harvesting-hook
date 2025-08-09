// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BaseVaultWrapper} from "src/VaultWrappers/Base/BaseVaultWrapper.sol";

/**
 * @notice This vault wrapper is intended for use with lending protocol vaults where the underlying vault share price monotonically increases.
 * @dev If the underlying vault share price drops, this vault may become insolvent. In cases of bad debt socialization within the lending protocol vaults, the share price can decrease.
 *      It is recommended to have an insurance fund capable of burning tokens to restore solvency if needed.
 *      No harvest operations will occur until the vault regains solvency.
 */
contract ERC4626VaultWrapper is BaseVaultWrapper {
    constructor() BaseVaultWrapper() {}

    function previewMint(uint256 shares) public view override returns (uint256) {
        return _underlyingVault().previewWithdraw(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _underlyingVault().previewMint(assets);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _underlyingVault().previewRedeem(assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _underlyingVault().previewDeposit(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _underlyingVault().convertToAssets(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return _underlyingVault().convertToShares(shares);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function _underlyingVault() internal view returns (IERC4626) {
        return IERC4626(asset());
    }

    function _getMaxWithdrawableUnderlyingAssets() internal view override returns (uint256) {
        IERC4626 underlyingVault = _underlyingVault();
        return underlyingVault.previewRedeem(underlyingVault.balanceOf(address(this)));
    }
}
