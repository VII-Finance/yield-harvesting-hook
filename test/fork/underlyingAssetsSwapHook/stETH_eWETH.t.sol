// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {
    BaseUnderlyingAssetsSwapHookTest
} from "test/fork/underlyingAssetsSwapHook/BaseUnderlyingAssetsSwapHookTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {SmoothYieldVault} from "src/SmoothYieldVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

/// @notice Fork test: UnderlyingAssetsSwapHook routing stETH ↔ WETH.
///
/// Vault chain:
///   stETH  →  stETHSmoothYieldVault      →  ERC4626VaultWrapper0  ┐
///                                                                    ├─ YieldHarvestingHook vault pool
///   WETH   →  euler WETH     →  ERC4626VaultWrapper1  ┘
///
///
/// The UnderlyingAssetsSwapHook is deployed on top of that vault pool, enabling
/// direct stETH ↔ WETH swaps at the asset level.
contract stETH_eWETH_UnderlyingAssetsSwapHookTest is BaseUnderlyingAssetsSwapHookTest {
    // ── Well-known mainnet addresses ─────────────────────────────────────────
    address constant stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant eWETHVault = 0xc97AF70AB043927A5d9b682e77d1AF3c52559A4e;

    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ── Deployed in _initializeConcreteVaults() ───────────────────────────────
    SmoothYieldVault stETHSmoothYieldVault;

    // ─────────────────────────────────────────────────────────────────────────
    //  Concrete vault setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
        deal(stETH, address(assetSwapHook), 0.001 ether);
        deal(weth, address(assetSwapHook), 0.001 ether);
    }

    /// @dev Deploy the SmoothYieldVault after the fork is active so it inherits
    ///      the forked block state (stETH contract is live at the fork block).
    function _initializeConcreteVaults() internal override {
        stETHSmoothYieldVault = new SmoothYieldVault(IERC20(stETH), 1 days, address(this));
    }

    function _getUnderlyingVaults() internal view override returns (MockERC4626, MockERC4626) {
        return (MockERC4626(address(stETHSmoothYieldVault)), MockERC4626(eWETHVault));
    }

    function setUpVaults(bool) public override {
        // Always use ERC4626-style wrappers (no Aave)
        super.setUpVaults(false);
    }

    /// @dev Override to pin the fork to a different block (e.g. when testing vaults
    ///      deployed after the default block).
    function _getForkBlock() internal pure override returns (uint256) {
        return 24796778;
    }

    /// @dev stETH and WETH track ETH 1:1, so SQRT_PRICE_1_1 is a good approximation
    ///      for the vault-wrapper pool initial price.
    function _getInitialPrice() internal pure override returns (uint160) {
        return Constants.SQRT_PRICE_1_1;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  stETH deal override
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `deal(stETH, ...)` doesn't work via vm.deal because stETH is a rebasing
    ///      token whose balance is computed from shares.  We obtain real stETH by
    ///      submitting ETH to Lido and transferring the minted tokens to the recipient.
    function deal(address token, address to, uint256 give) internal override {
        if (token == stETH) {
            // Add a small buffer to absorb Lido's ±1-wei rounding.
            vm.deal(address(this), give + 10);
            ILido(stETH).submit{value: give + 10}(address(0));
            IERC20(stETH).transfer(to, give + 5);
        } else {
            super.deal(token, to, give);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  receive() — needed so vm.deal can give ETH to this contract for Lido
    // ─────────────────────────────────────────────────────────────────────────

    // BaseVaultsTest already defines receive() external payable; no need to redefine it.
}
