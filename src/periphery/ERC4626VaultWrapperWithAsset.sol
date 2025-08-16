// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20, ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {BaseAssetToVaultWrapperHelper} from "src/periphery/Base/BaseAssetToVaultWrapperHelper.sol";

///@notice this is an external helper contract that mint users ERC4626VaultWrapper shares given underlying assets
/// as opposed to the core VaultWrapper itself that mints users ERC4626VaultWrapper shares given underlying vault shares

///@dev we could have made this functionality internal to the protocol but we didn't think the possibility of rounding errors mishandled was worth the risk
///The trade off is that users have spend a bit more gas. (one additional external call and one additional token transfer could have been avoided if this was internal)
contract AssetToVaultWrapperHelperWithERC4626 is BaseAssetToVaultWrapperHelper {
    using SafeERC20 for IERC20;

    IERC4626 public immutable vaultWrapper;
    IERC4626 public immutable underlyingVault;
    IERC20 public immutable underlyingAsset;

    constructor(IERC4626 _vaultWrapper) {
        vaultWrapper = _vaultWrapper;
        underlyingVault = IERC4626(_vaultWrapper.asset());
        underlyingAsset = IERC20(underlyingVault.asset());
    }

    function totalAssets() public view returns (uint256) {
        return underlyingVault.convertToAssets(underlyingVault.balanceOf(address(vaultWrapper)));
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 underlyingVaultSharesMinted = underlyingVault.previewDeposit(assets);
        return vaultWrapper.previewDeposit(underlyingVaultSharesMinted);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 underlyingVaultSharesNeeded = vaultWrapper.previewMint(shares);
        return underlyingVault.previewMint(underlyingVaultSharesNeeded);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 underlyingVaultSharesReceived = underlyingVault.previewWithdraw(assets);
        return vaultWrapper.previewWithdraw(underlyingVaultSharesReceived);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 underlyingVaultSharesReceived = vaultWrapper.previewRedeem(shares);
        return underlyingVault.previewRedeem(underlyingVaultSharesReceived);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        return _deposit(vaultWrapper, address(underlyingVault), underlyingAsset, msg.sender, assets, receiver);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        return _mint(vaultWrapper, address(underlyingVault), underlyingAsset, msg.sender, shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address) external returns (uint256 shares) {
        return _withdraw(vaultWrapper, address(underlyingVault), msg.sender, assets, receiver);
    }

    function redeem(uint256 shares, address receiver, address) external returns (uint256 assets) {
        return _redeem(vaultWrapper, address(underlyingVault), msg.sender, shares, receiver);
    }
}
