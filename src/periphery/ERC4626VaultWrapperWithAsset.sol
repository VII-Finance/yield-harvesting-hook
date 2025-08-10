// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20, ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

///@notice this is an external helper contract that mint users ERC4626VaultWrapper shares given underlying assets
/// as opposed to the core VaultWrapper itself that mints users ERC4626VaultWrapper shares given underlying vault shares

///@dev we could have made this functionality internal to the protocol but we didn't think the possibility of rounding errors mishandled was worth the risk
///The trade off is that users have spend a bit more gas. (one additional external call and one additional token transfer could have been avoided if this was internal)
contract ERC4626VaultWrapperWithAsset is ERC4626 {
    using SafeERC20 for IERC20;

    IERC4626 public immutable vaultWrapper;
    IERC4626 public immutable underlyingVault;

    constructor(IERC4626 _vaultWrapper)
        ERC20("SwapHook", "SWAP")
        ERC4626(IERC20(IERC4626(_vaultWrapper.asset()).asset()))
    {
        vaultWrapper = _vaultWrapper;
        underlyingVault = IERC4626(_vaultWrapper.asset());
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 underlyingVaultSharesMinted = underlyingVault.previewDeposit(assets);
        return vaultWrapper.previewDeposit(underlyingVaultSharesMinted);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 underlyingVaultSharesNeeded = vaultWrapper.previewMint(shares);
        return underlyingVault.previewMint(underlyingVaultSharesNeeded);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 underlyingVaultSharesReceived = underlyingVault.previewWithdraw(assets);
        return vaultWrapper.previewWithdraw(underlyingVaultSharesReceived);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 underlyingVaultSharesReceived = vaultWrapper.previewRedeem(shares);
        return underlyingVault.previewRedeem(underlyingVaultSharesReceived);
    }

    function depositAssets(IERC4626 vaultWrapper, IERC20 asset, address receiver, uint256 amount)
        external
        returns (uint256)
    {
        IERC4626 underlyingVault = IERC4626(vaultWrapper.asset());

        uint256 underlyingVaultSharesMinted;
        try underlyingVault.deposit(amount, address(this)) returns (uint256 shares) {
            underlyingVaultSharesMinted = shares;
        } catch {
            SafeERC20.forceApprove(asset, address(underlyingVault), type(uint256).max);
            underlyingVaultSharesMinted = underlyingVault.deposit(amount, address(this));
        }

        try vaultWrapper.deposit(underlyingVaultSharesMinted, receiver) returns (uint256 vaultWrapperShares) {
            return vaultWrapperShares;
        } catch {
            underlyingVault.approve(address(vaultWrapper), type(uint256).max);
            return vaultWrapper.deposit(underlyingVaultSharesMinted, receiver);
        }
    }

    function redeemVaultWrapperShares(IERC4626 vaultWrapper, address receiver, uint256 vaultWrapperShares)
        external
        returns (uint256)
    {
        IERC4626 underlyingVault = IERC4626(vaultWrapper.asset());
        uint256 underlyingVaultSharesReceived = vaultWrapper.redeem(vaultWrapperShares, address(this), address(this));

        return underlyingVault.redeem(underlyingVaultSharesReceived, receiver, address(this));
    }

    function mintVaultWrapperShares(IERC4626 vaultWrapper, IERC20 asset, address receiver, uint256 vaultWrapperShares)
        external
        returns (uint256 underlyingAssetsNeeded)
    {
        IERC4626 underlyingVault = IERC4626(vaultWrapper.asset());

        uint256 underlyingVaultSharesToMint = vaultWrapper.previewMint(vaultWrapperShares);
        // underlyingAssetsNeeded = underlyingVault.previewMint(underlyingVaultSharesToMint);

        try underlyingVault.mint(underlyingVaultSharesToMint, address(this)) returns (uint256 assets) {
            underlyingAssetsNeeded = assets;
        } catch {
            SafeERC20.forceApprove(asset, address(underlyingVault), type(uint256).max);
            underlyingAssetsNeeded = underlyingVault.mint(underlyingVaultSharesToMint, address(this));
        }

        //now use the newly minted underlyingVaultShare to mint the vaultWrapperShares
        try vaultWrapper.mint(vaultWrapperShares, receiver) returns (uint256 actualVaultWrapperSharesMinted) {
            require(actualVaultWrapperSharesMinted == vaultWrapperShares, "Minted shares do not match");
        } catch {
            underlyingVault.approve(address(vaultWrapper), type(uint256).max);
            uint256 actualVaultWrapperSharesMinted = vaultWrapper.mint(vaultWrapperShares, receiver);
            require(actualVaultWrapperSharesMinted == vaultWrapperShares, "Minted shares do not match");
        }
    }

    function withdrawAssets(IERC4626 vaultWrapper, address receiver, uint256 assetAmount)
        external
        returns (uint256 vaultWrapperSharesBurnt)
    {
        IERC4626 underlyingVault = IERC4626(vaultWrapper.asset());
        uint256 underlyingVaultSharesToWithdraw = vaultWrapper.previewWithdraw(assetAmount);

        // withdraw underlying vault shares from the vault wrapper
        vaultWrapperSharesBurnt = vaultWrapper.withdraw(underlyingVaultSharesToWithdraw, address(this), address(this));

        // now withdraw the underlying assets from the underlying vault
        uint256 underlyingSharesBurnt =
            underlyingVault.withdraw(underlyingVaultSharesToWithdraw, receiver, address(this));

        require(underlyingSharesBurnt == underlyingVaultSharesToWithdraw, "Withdrawn shares do not match");
    }
}
