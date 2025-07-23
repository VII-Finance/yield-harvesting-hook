// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Fuzzers} from "lib/v4-periphery/lib/v4-core/src/test/Fuzzers.sol";

import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {ERC4626VaultWrapperFactory} from "src/ERC4626VaultWrapperFactory.sol";
import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {FeeMath, PositionConfig} from "test/utils/libraries/FeeMath.sol";
import {console} from "forge-std/console.sol";

contract YieldHarvestingHookTest is Fuzzers, Test {
    using StateLibrary for PoolManager;

    PoolManager public poolManager;
    YieldHarvestingHook public yieldHarvestingHook;
    ERC4626VaultWrapperFactory public vaultWrappersFactory;

    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public swapRouter;

    MockERC4626 public underlyingVault0;
    MockERC4626 public underlyingVault1;
    MockERC20 public asset0;
    MockERC20 public asset1;
    ERC4626VaultWrapper public vaultWrapper0;
    ERC4626VaultWrapper public vaultWrapper1;

    PoolKey public poolKey;

    address public poolManagerOwner = makeAddr("poolManagerOwner");
    uint160 hookPermissionCount = 14;
    uint160 clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    function setUp() public {
        poolManager = new PoolManager(poolManagerOwner);

        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);

        yieldHarvestingHook = YieldHarvestingHook(
            payable(
                address(
                    uint160(
                        type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    )
                )
            )
        );

        deployCodeTo("YieldHarvestingHook", abi.encode(poolManager), address(yieldHarvestingHook));

        vaultWrappersFactory = new ERC4626VaultWrapperFactory(address(yieldHarvestingHook));

        // Deploy as assetA, underlyingVaultB, etc.
        MockERC20 assetA = new MockERC20();
        MockERC4626 underlyingVaultB = new MockERC4626(assetA);
        ERC4626VaultWrapper vaultWrapperA = vaultWrappersFactory.createVaultWrapper(underlyingVaultB);

        MockERC20 assetB = new MockERC20();
        MockERC4626 underlyingVaultA = new MockERC4626(assetB);
        ERC4626VaultWrapper vaultWrapperB = vaultWrappersFactory.createVaultWrapper(underlyingVaultA);

        // Compare vaultWrapper addresses and assign 0/1 based on which is lower
        if (address(vaultWrapperA) < address(vaultWrapperB)) {
            asset0 = assetA;
            underlyingVault0 = underlyingVaultB;
            vaultWrapper0 = vaultWrapperA;

            asset1 = assetB;
            underlyingVault1 = underlyingVaultA;
            vaultWrapper1 = vaultWrapperB;
        } else {
            asset0 = assetB;
            underlyingVault0 = underlyingVaultA;
            vaultWrapper0 = vaultWrapperB;

            asset1 = assetA;
            underlyingVault1 = underlyingVaultB;
            vaultWrapper1 = vaultWrapperA;
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(address(vaultWrapper0)),
            currency1: Currency.wrap(address(vaultWrapper1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: yieldHarvestingHook
        });
    }

    function modifyLiquidity(ModifyLiquidityParams memory params, uint160 sqrtPriceX96) internal {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        if (params.liquidityDelta != 0) {
            //why is above estimate incorrect?
            amount0 = amount0 * 2 + 2;
            amount1 = amount1 * 2 + 2;

            asset0.mint(address(this), amount0);
            asset1.mint(address(this), amount1);

            asset0.approve(address(underlyingVault0), amount0);
            asset1.approve(address(underlyingVault1), amount1);

            uint256 underlyingVaultShares0 = underlyingVault0.deposit(amount0, address(this));
            uint256 underlyingVaultShares1 = underlyingVault1.deposit(amount1, address(this));

            underlyingVault0.approve(address(vaultWrapper0), underlyingVaultShares0);
            underlyingVault1.approve(address(vaultWrapper1), underlyingVaultShares1);

            vaultWrapper0.deposit(underlyingVaultShares0, address(this));
            vaultWrapper1.deposit(underlyingVaultShares1, address(this));

            //approve this to the liquidity router
            vaultWrapper0.approve(address(modifyLiquidityRouter), type(uint256).max);
            vaultWrapper1.approve(address(modifyLiquidityRouter), type(uint256).max);
        }

        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");
    }

    function test_donateLiquidity(
        ModifyLiquidityParams memory params,
        int256 startingSqrtPriceX96,
        uint256 yield0,
        uint256 yield1
    ) public {
        poolManager.initialize(poolKey, createRandomSqrtPriceX96(poolKey.tickSpacing, startingSqrtPriceX96));

        //liquidity to full range to make test simpler
        params.tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        params.tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        params.liquidityDelta = bound(0, 1, type(int128).max);

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());

        params = createFuzzyLiquidityParams(poolKey, params, sqrtRatioX96);

        modifyLiquidity(params, sqrtRatioX96);

        yield0 = bound(yield0, 1, uint128(type(int128).max));
        yield1 = bound(yield1, 1, uint128(type(int128).max));

        //we mint this tokens to the underlying vaults
        asset0.mint(address(underlyingVault0), yield0);
        asset1.mint(address(underlyingVault1), yield1);

        //make sure poolManager balance has increased
        uint256 poolManagerBalance0Before = poolKey.currency0.balanceOf(address(poolManager));
        uint256 poolManagerBalance1Before = poolKey.currency1.balanceOf(address(poolManager));

        // do a small swap so to make sure we harvest and donate
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1), // exact input, 0 for 1
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(params.tickLower) + 1
        });

        vaultWrapper0.approve(address(swapRouter), type(uint256).max);
        vaultWrapper1.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        //make sure balance has increase by yield0 and yield1
        assertApproxEqAbs(
            poolKey.currency0.balanceOf(address(poolManager)) - poolManagerBalance0Before,
            yield0,
            1,
            "PoolManager balance for currency0 should increase by yield0"
        );
        assertApproxEqAbs(
            poolKey.currency1.balanceOf(address(poolManager)) - poolManagerBalance1Before,
            yield1,
            1,
            "PoolManager balance for currency1 should increase by yield1"
        );

        PositionConfig memory config = PositionConfig({
            poolKey: poolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            salt: params.salt
        });

        BalanceDelta feesOwed = FeeMath.getFeesOwed(poolManager, config, address(modifyLiquidityRouter));

        //make sure feesOwed is equal to yield0 and yield1
        assertApproxEqAbs(feesOwed.amount0(), int256(yield0), 1, "feesOwed amount0 mismatch");
        assertApproxEqAbs(feesOwed.amount1(), int256(yield1), 1, "feesOwed amount1 mismatch");

        //increase liquidity by 0 and see the balance increase
        uint256 balance0Before = poolKey.currency0.balanceOfSelf();
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();

        params.liquidityDelta = 0;
        modifyLiquidity(params, sqrtRatioX96);

        assertApproxEqAbs(
            poolKey.currency0.balanceOfSelf() - balance0Before,
            yield0,
            1,
            "Balance for currency0 should increase by yield0"
        );
        assertApproxEqAbs(
            poolKey.currency1.balanceOfSelf() - balance1Before,
            yield1,
            1,
            "Balance for currency1 should increase by yield1"
        );
    }
}
