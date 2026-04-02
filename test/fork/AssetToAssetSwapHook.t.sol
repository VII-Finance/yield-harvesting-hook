// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseAssetSwapHookForkTest} from "test/fork/BaseAssetSwapHookForkTest.t.sol";
import {AssetToAssetSwapHookForERC4626} from "src/periphery/AssetToAssetSwapHookForERC4626.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {LiquidityHelper} from "src/periphery/LiquidityHelper.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract AssetToAssetSwapHookForkTest is BaseAssetSwapHookForkTest {
    uint160 constant SWAP_HOOK_PERMISSIONS = uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    AssetToAssetSwapHookForERC4626 assetToAssetSwapHook;
    LiquidityHelper liquidityHelper;

    // The underlying vault wrapper pool key (used for liquidity operations)
    PoolKey public poolKey;

    function _deployHookAndInitPool() internal override {
        (, bytes32 salt) = HookMiner.find(
            address(this),
            SWAP_HOOK_PERMISSIONS,
            type(AssetToAssetSwapHookForERC4626).creationCode,
            abi.encode(poolManager, yieldHarvestingHook, initialOwner)
        );

        assetToAssetSwapHook =
            new AssetToAssetSwapHookForERC4626{salt: salt}(poolManager, yieldHarvestingHook, initialOwner);

        liquidityHelper = new LiquidityHelper(evc, positionManager, yieldHarvestingHook);

        assetsPoolKey = PoolKey({
            currency0: Currency.wrap(address(asset0)),
            currency1: Currency.wrap(address(asset1)),
            fee: 18,
            tickSpacing: 1,
            hooks: assetToAssetSwapHook
        });

        poolKey = PoolKey({
            currency0: _IERC20ToCurrency(asset0),
            currency1: _IERC20ToCurrency(asset1),
            fee: 18,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(assetsPoolKey, Constants.SQRT_PRICE_1_1);
    }

    function _hookDataForExactIn() internal view override returns (bytes memory) {
        (IERC4626 associatedVault0, IERC4626 associatedVault1) = sortVaultWrappers(
            vaultWrapper0,
            vaultWrapper1,
            Currency.unwrap(assetsPoolKey.currency0),
            Currency.unwrap(assetsPoolKey.currency1)
        );
        return abi.encode(associatedVault0, associatedVault1);
    }

    function _setupBeforeExactOut() internal override {
        (IERC4626 associatedVault0, IERC4626 associatedVault1) =
            sortVaultWrappers(vaultWrapper0, vaultWrapper1, address(asset0), address(asset1));
        vm.startPrank(initialOwner);
        assetToAssetSwapHook.setDefaultVaultWrappers(assetsPoolKey, associatedVault0, associatedVault1);
        vm.stopPrank();
    }

    function test_setDefaultVaultWrappers() public {
        vm.expectRevert();
        assetToAssetSwapHook.setDefaultVaultWrappers(assetsPoolKey, IERC4626(address(0)), IERC4626(address(0)));

        (IERC4626 associatedVault0, IERC4626 associatedVault1) =
            sortVaultWrappers(vaultWrapper0, vaultWrapper1, address(asset0), address(asset1));

        vm.startPrank(initialOwner);
        assetToAssetSwapHook.setDefaultVaultWrappers(assetsPoolKey, associatedVault0, associatedVault1);
    }

    function testMintAndIncreasePosition(uint128 liquidityToAdd) public {
        liquidityToAdd = uint128(bound(liquidityToAdd, 10, 1e8));

        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);

        deal(address(asset0), address(this), 2 * liquidityToAdd);
        deal(address(asset1), address(this), 2 * liquidityToAdd);

        asset0.approve(address(liquidityHelper), type(uint256).max);
        asset1.approve(address(liquidityHelper), type(uint256).max);

        poolKey.currency0 = Currency.wrap(address(asset0));
        poolKey.currency1 = Currency.wrap(address(asset1));

        (uint256 tokenId) = liquidityHelper.mintPosition(
            poolKey,
            tickLower,
            tickUpper,
            liquidityToAdd,
            uint128(2 * liquidityToAdd),
            uint128(2 * liquidityToAdd),
            address(this),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        deal(address(asset0), address(this), 2 * liquidityToAdd);
        deal(address(asset1), address(this), 2 * liquidityToAdd);

        positionManager.approve(address(liquidityHelper), tokenId);

        liquidityHelper.increaseLiquidity(
            poolKey,
            tokenId,
            liquidityToAdd,
            uint128(2 * liquidityToAdd),
            uint128(2 * liquidityToAdd),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        liquidityHelper.decreaseLiquidity(
            poolKey, tokenId, liquidityToAdd, 0, 0, address(this), abi.encode(vaultWrapper0, vaultWrapper1)
        );
    }
}
