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
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LiquidityHelper} from "src/periphery/LiquidityHelper.sol";

contract AssetToAssetSwapHookTest is YieldHarvestingHookTest {
    PositionManager public positionManager;
    address public weth;
    address public evc;
    AssetToAssetSwapHookForERC4626 assetToAssetSwapHook;
    LiquidityHelper liquidityHelper;

    address initialOwner = makeAddr("initialOwner");

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
            abi.encode(poolManager, yieldHarvestingHook, initialOwner)
        );

        assetToAssetSwapHook =
            new AssetToAssetSwapHookForERC4626{salt: salt}(poolManager, yieldHarvestingHook, initialOwner);

        liquidityHelper = new LiquidityHelper(evc, positionManager, yieldHarvestingHook);

        assetsPoolKey = PoolKey({
            currency0: isCurrency0SameAsAsset0 ? Currency.wrap(address(asset0)) : Currency.wrap(address(asset1)),
            currency1: isCurrency0SameAsAsset0 ? Currency.wrap(address(asset1)) : Currency.wrap(address(asset0)),
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hooks: assetToAssetSwapHook
        });

        poolManager.initialize(assetsPoolKey, Constants.SQRT_PRICE_1_1);
    }

    function _currencyToIERC20(Currency currency) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(currency));
    }

    function sortVaultWrappers(IERC4626 vaultWrapperA, IERC4626 vaultWrapperB, address asset0, address asset1)
        internal
        view
        returns (IERC4626 vaultWrapper0, IERC4626 vaultWrapper1)
    {
        IERC4626 underlyingVaultA = IERC4626(vaultWrapperA.asset());
        IERC4626 underlyingVaultB = IERC4626(vaultWrapperB.asset());

        if (underlyingVaultA.asset() == asset0 && underlyingVaultB.asset() == asset1) {
            return (vaultWrapperA, vaultWrapperB);
        } else if (underlyingVaultA.asset() == asset1 && underlyingVaultB.asset() == asset0) {
            return (vaultWrapperB, vaultWrapperA);
        } else {
            revert("Vault wrappers do not wrap the correct assets");
        }
    }

    function test_setDefaultVaultWrappers() public {
        vm.expectRevert();
        assetToAssetSwapHook.setDefaultVaultWrappers(assetsPoolKey, IERC4626(address(0)), IERC4626(address(0)));

        (IERC4626 associatedVault0, IERC4626 associatedVault1) =
            sortVaultWrappers(vaultWrapper0, vaultWrapper1, address(asset0), address(asset1));

        vm.startPrank(initialOwner);
        assetToAssetSwapHook.setDefaultVaultWrappers(assetsPoolKey, associatedVault0, associatedVault1);
    }

    function test_assetsSwapExactAmountIn(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 10, 1e18);

        Currency currencyIn = zeroForOne ? assetsPoolKey.currency0 : assetsPoolKey.currency1;
        Currency currencyOut = zeroForOne ? assetsPoolKey.currency1 : assetsPoolKey.currency0;

        deal(Currency.unwrap(currencyIn), address(this), amountIn);
        _currencyToIERC20(currencyIn).approve(address(swapRouter), amountIn);

        //we assume that prior to the mint, poolManager already has some asset0 that user can take it out of
        deal(Currency.unwrap(currencyIn), address(poolManager), amountIn);

        uint256 assetBalanceBefore = currencyOut.balanceOf(address(this));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        (IERC4626 associatedVault0, IERC4626 associatedVault1) = sortVaultWrappers(
            vaultWrapper0,
            vaultWrapper1,
            Currency.unwrap(assetsPoolKey.currency0),
            Currency.unwrap(assetsPoolKey.currency1)
        );

        BalanceDelta swapDelta = swapRouter.swap(
            assetsPoolKey,
            swapParams,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(associatedVault0, associatedVault1)
        );

        uint256 assetOut = SafeCast.toUint256(zeroForOne ? swapDelta.amount1() : swapDelta.amount0());
        assertEq(assetOut, currencyOut.balanceOf(address(this)) - assetBalanceBefore, "Incorrect asset out amount");
    }

    function test_assetsSwapExactAmountOut(uint256 amountOut, bool zeroForOne) public {
        amountOut = bound(amountOut, 10, 1e18);

        Currency currencyIn = zeroForOne ? assetsPoolKey.currency0 : assetsPoolKey.currency1;
        Currency currencyOut = zeroForOne ? assetsPoolKey.currency1 : assetsPoolKey.currency0;

        deal(Currency.unwrap(currencyIn), address(this), 2 * amountOut);
        _currencyToIERC20(currencyIn).approve(address(swapRouter), 2 * amountOut);

        //we assume that prior to the swap, poolManager already has some asset1 that user can take it out of
        deal(Currency.unwrap(currencyIn), address(poolManager), 2 * amountOut);

        uint256 assetBalanceBefore = currencyIn.balanceOf(address(this));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        (IERC4626 associatedVault0, IERC4626 associatedVault1) =
            sortVaultWrappers(vaultWrapper0, vaultWrapper1, address(asset0), address(asset1));

        vm.startPrank(initialOwner);
        assetToAssetSwapHook.setDefaultVaultWrappers(assetsPoolKey, associatedVault0, associatedVault1);
        vm.stopPrank();

        BalanceDelta swapDelta = swapRouter.swap(
            assetsPoolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 assetIn = SafeCast.toUint256(zeroForOne ? -swapDelta.amount0() : -swapDelta.amount1());
        assertEq(assetIn, assetBalanceBefore - currencyIn.balanceOf(address(this)), "Incorrect asset out amount");
    }

    function testMintAndIncreasePosition(uint128 liquidityToAdd) public {
        liquidityToAdd = uint128(bound(liquidityToAdd, 1, 1e18));

        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);

        deal(address(asset0), address(this), liquidityToAdd);
        deal(address(asset1), address(this), liquidityToAdd);

        asset0.approve(address(liquidityHelper), type(uint256).max);
        asset1.approve(address(liquidityHelper), type(uint256).max);

        poolKey.currency0 = Currency.wrap(address(asset0));
        poolKey.currency1 = Currency.wrap(address(asset1));

        (uint256 tokenId) = liquidityHelper.mintPosition(
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

        positionManager.approve(address(liquidityHelper), tokenId);

        liquidityHelper.increaseLiquidity(
            poolKey,
            tokenId,
            liquidityToAdd,
            uint128(liquidityToAdd),
            uint128(liquidityToAdd),
            abi.encode(vaultWrapper0, vaultWrapper1)
        );

        liquidityHelper.decreaseLiquidity(
            poolKey, tokenId, liquidityToAdd, 0, 0, address(this), abi.encode(vaultWrapper0, vaultWrapper1)
        );
    }
}
