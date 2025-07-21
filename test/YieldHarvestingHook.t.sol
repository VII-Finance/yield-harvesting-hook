// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Fuzzers} from "lib/v4-periphery/lib/v4-core/src/test/Fuzzers.sol";

import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {ERC4626VaultWrappersFactory} from "src/ERC4626VaultWrappersFactory.sol";
import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {FeeMath, PositionConfig} from "test/utils/libraries/FeeMath.sol";
import {console} from "forge-std/console.sol";

contract YieldHarvestingHookTest is Fuzzers, Test {
    using StateLibrary for PoolManager;

    PoolManager public poolManager;
    YieldHarvestingHook public yieldHarvestingHook;
    ERC4626VaultWrappersFactory public vaultWrappersFactory;

    PoolModifyLiquidityTest public modifyLiquidityRouter;

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

        vaultWrappersFactory = new ERC4626VaultWrappersFactory(address(yieldHarvestingHook));

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

        //why is above estimate incorrect?
        amount0 = amount0 * 2 + 1;
        amount1 = amount1 * 2 + 1;

        asset0.mint(address(this), amount0);
        asset1.mint(address(this), amount1);

        asset0.approve(address(vaultWrapper0), amount0);
        asset1.approve(address(vaultWrapper1), amount1);

        if (amount0 > 1) {
            vaultWrapper0.deposit(amount0, address(this));
        }
        if (amount1 > 1) {
            vaultWrapper1.deposit(amount1, address(this));
        }

        //approve this to the liquidity router
        vaultWrapper0.approve(address(modifyLiquidityRouter), type(uint256).max);
        vaultWrapper1.approve(address(modifyLiquidityRouter), type(uint256).max);

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

        yield0 = bound(yield0, 1, type(uint128).max);
        yield1 = bound(yield1, 1, type(uint128).max);

        //we mint this tokens to the underlying vaults
        asset0.mint(address(underlyingVault0), yield0);
        asset1.mint(address(underlyingVault1), yield1);

        //remove 0 liquidity to make sure we harvest and donate
        params.liquidityDelta = 0;
        modifyLiquidity(params, sqrtRatioX96);

        //let's now make the vault some profit so that in the next step we can harvest and donate
        PositionConfig memory config = PositionConfig({
            poolKey: poolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            salt: params.salt
        });

        BalanceDelta feesOwed = FeeMath.getFeesOwed(poolManager, config, address(modifyLiquidityRouter));

        //make sure feesOwed is equal to yield0 and yield1
        assertEq(feesOwed.amount0(), int256(yield0), "feesOwed amount0 mismatch");
        assertEq(feesOwed.amount1(), int256(yield1), "feesOwed amount1 mismatch");

        // console.log("feesOwed token0: %s, token1: %s", feesOwed.amount0(), feesOwed.amount1());
    }
}
