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

interface IDepositAdapter {
    function depositETHForWeETH(address _referral) external payable returns (uint256);
}

interface IWeETH {
    function unwrap(uint256 amount) external returns (uint256);
}

/// @notice Fork test: UnderlyingAssetsSwapHook routing eETH ↔ WETH.
///
/// Vault chain:
///   eETH  →  eETHSmoothYieldVault      →  ERC4626VaultWrapper0  ┐
///                                                                    ├─ YieldHarvestingHook vault pool
///   WETH   →  Morpho Steakhouse WETH     →  ERC4626VaultWrapper1  ┘
///
///
/// The UnderlyingAssetsSwapHook is deployed on top of that vault pool, enabling
/// direct eETH ↔ WETH swaps at the asset level.
contract EETH_EulerVaultWETH_UnderlyingAssetsSwapHookTest is BaseUnderlyingAssetsSwapHookTest {
    // ── Well-known mainnet addresses ─────────────────────────────────────────
    address constant eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2; //eeth
    address constant eulerVaultWETHVault = 0xc97AF70AB043927A5d9b682e77d1AF3c52559A4e;
    IDepositAdapter constant depositAdapter = IDepositAdapter(0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2);
    IWeETH constant weETH = IWeETH(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);

    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ── Deployed in _initializeConcreteVaults() ───────────────────────────────
    SmoothYieldVault eETHSmoothYieldVault;

    // ─────────────────────────────────────────────────────────────────────────
    //  Concrete vault setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
    }

    /// @dev Deploy the SmoothYieldVault after the fork is active so it inherits
    ///      the forked block state (eETH contract is live at the fork block).
    function _initializeConcreteVaults() internal override {
        eETHSmoothYieldVault = new SmoothYieldVault(IERC20(eETH), 1 days, address(this));
    }

    function _getUnderlyingVaults() internal view override returns (MockERC4626, MockERC4626) {
        return (MockERC4626(address(eETHSmoothYieldVault)), MockERC4626(eulerVaultWETHVault));
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

    /// @dev eETH and WETH track ETH 1:1, so SQRT_PRICE_1_1 is a good approximation
    ///      for the vault-wrapper pool initial price.
    function _getInitialPrice() internal pure override returns (uint160) {
        return Constants.SQRT_PRICE_1_1;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  eETH deal override
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `deal(eETH, ...)` doesn't work via vm.deal because eETH is a rebasing
    ///      token whose balance is computed from shares.  We obtain real eETH by
    ///      submitting ETH to Lido and transferring the minted tokens to the recipient.
    function deal(address token, address to, uint256 give) internal override {
        if (token == eETH) {
            deal(address(this), give + 10);
            depositAdapter.depositETHForWeETH{value: give + 10}(address(0));
            weETH.unwrap(IERC20(address(weETH)).balanceOf(address(this)));
            if (to != address(this)) IERC20(eETH).transfer(to, give);
        } else {
            super.deal(token, to, give);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  receive() — needed so vm.deal can give ETH to this contract for Lido
    // ─────────────────────────────────────────────────────────────────────────

    // BaseVaultsTest already defines receive() external payable; no need to redefine it.
}
