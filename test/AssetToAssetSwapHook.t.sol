// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {YieldHarvestingHookTest} from "test/YieldHarvestingHook.t.sol";
import {AssetToAssetSwapHookForERC4626} from "src/periphery/AssetToAssetSwapHookForERC4626.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector//EthereumVaultConnector.sol";
import {
    PositionManager, IAllowanceTransfer, IPositionDescriptor, IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";
import {WETH} from "lib/solady/src/tokens/WETH.sol";

contract AssetToAssetSwapHookTest is YieldHarvestingHookTest {
    PositionManager public positionManager;
    address public weth;
    address public evc;
    AssetToAssetSwapHookForERC4626 assetToAssetSwapHook;

    using StateLibrary for PoolManager;

    uint160 constant SWAP_HOOK_PERMISSIONS =
        uint160(Hooks.BEFORE_SWAP_FLAG) | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    PoolKey assetsPoolKey;
    PoolKey mixedAssetPoolKey;

    function setUp() public override {
        super.setUp();

        evc = address(new EthereumVaultConnector());
        weth = address(new WETH());
        positionManager = new PositionManager(
            poolManager, IAllowanceTransfer(address(0)), 0, IPositionDescriptor(address(0)), IWETH9(address(weth))
        );

        setUpVaults(false);

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());

        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
            liquidityDelta: 1e20,
            salt: keccak256(abi.encodePacked(address(this), SWAP_HOOK_PERMISSIONS))
        });

        modifyLiquidity(liquidityParams, sqrtRatioX96);

        modifyMixedLiquidity(liquidityParams, sqrtRatioX96);

        Currency currency0 =
            address(asset0) < address(asset1) ? Currency.wrap(address(asset0)) : Currency.wrap(address(asset1));

        bool isCurrency0SameAsAsset0 = currency0 == Currency.wrap(address(asset0));

        (, bytes32 salt) = HookMiner.find(
            address(this),
            SWAP_HOOK_PERMISSIONS,
            type(AssetToAssetSwapHookForERC4626).creationCode,
            abi.encode(evc, poolManager, positionManager, yieldHarvestingHook)
        );

        assetToAssetSwapHook =
            new AssetToAssetSwapHookForERC4626{salt: salt}(evc, poolManager, positionManager, yieldHarvestingHook);

        assetsPoolKey = PoolKey({
            currency0: isCurrency0SameAsAsset0 ? Currency.wrap(address(asset0)) : Currency.wrap(address(asset1)),
            currency1: isCurrency0SameAsAsset0 ? Currency.wrap(address(asset1)) : Currency.wrap(address(asset0)),
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hooks: assetToAssetSwapHook
        });

        poolManager.initialize(assetsPoolKey, Constants.SQRT_PRICE_1_1);
    }

    function test_assetsSwapExactAmountIn() public {
        uint256 amountIn = 1e18;

        asset0.mint(address(this), amountIn);
        asset0.approve(address(swapRouter), amountIn);

        //we assume that prior to the mint, poolManager already has some asset0 that user can take it out of
        asset0.mint(address(poolManager), amountIn);

        uint256 asset1BalanceBefore = asset1.balanceOf(address(this));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        BalanceDelta swapDelta = swapRouter.swap(
            assetsPoolKey,
            swapParams,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        uint256 asset1Out = SafeCast.toUint256(swapDelta.amount1());
        assertEq(asset1Out, asset1.balanceOf(address(this)) - asset1BalanceBefore, "Incorrect asset1 out amount");
    }

    function test_assetsSwapExactAmountOut() public {
        uint256 amountOut = 1e18;

        asset1.mint(address(this), 2 * amountOut);
        asset1.approve(address(swapRouter), 2 * amountOut);

        //we assume that prior to the swap, poolManager already has some asset1 that user can take it out of
        asset1.mint(address(poolManager), 2 * amountOut);

        uint256 asset1BalanceBefore = asset1.balanceOf(address(this));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta swapDelta = swapRouter.swap(
            assetsPoolKey,
            swapParams,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        uint256 asset1In = SafeCast.toUint256(-swapDelta.amount1());
        assertEq(asset1In, asset1BalanceBefore - asset1.balanceOf(address(this)), "Incorrect asset1 out amount");
    }

    function testMintAndIncreasePosition(uint128 liquidityToAdd) public {
        liquidityToAdd = uint128(bound(liquidityToAdd, 1, 1e18));

        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);

        deal(address(asset0), address(this), liquidityToAdd);
        deal(address(asset1), address(this), liquidityToAdd);

        asset0.approve(address(assetToAssetSwapHook), type(uint256).max);
        asset1.approve(address(assetToAssetSwapHook), type(uint256).max);

        poolKey.currency0 = Currency.wrap(address(asset0));
        poolKey.currency1 = Currency.wrap(address(asset1));

        (uint256 tokenId) = assetToAssetSwapHook.mintPosition(
            poolKey,
            tickLower,
            tickUpper,
            liquidityToAdd,
            uint128(liquidityToAdd),
            uint128(liquidityToAdd),
            address(this),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        deal(address(asset0), address(this), liquidityToAdd);
        deal(address(asset1), address(this), liquidityToAdd);

        positionManager.approve(address(assetToAssetSwapHook), tokenId);

        assetToAssetSwapHook.increaseLiquidity(
            poolKey,
            tokenId,
            liquidityToAdd,
            uint128(liquidityToAdd),
            uint128(liquidityToAdd),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        assetToAssetSwapHook.decreaseLiquidity(
            poolKey, tokenId, liquidityToAdd, 0, 0, address(this), abi.encode(vaultWrapper0, vaultWrapper1)
        );
    }
}
