// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/BaseVaultsTest.t.sol";
import {UnderlyingAssetsSwapHook} from "src/periphery/UnderlyingAssetsSwapHook/UnderlyingAssetsSwapHook.sol";
import {
    UnderlyingAssetsSwapHookFactory
} from "src/periphery/UnderlyingAssetsSwapHook/UnderlyingAssetsSwapHookFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Base test for UnderlyingAssetsSwapHook on a mainnet fork.
///
/// Extends BaseVaultsTest (which deploys a YieldHarvestingHook + ERC4626VaultWrapperFactory)
/// to also deploy an UnderlyingAssetsSwapHookFactory and an UnderlyingAssetsSwapHook,
/// then runs shared exact-in / exact-out swap tests against the raw-asset pool.
///
/// Concrete subclasses must override:
///   - _getUnderlyingVaults()  — return the two underlying ERC4626 vaults
///   - _getInitialPrice()      — return a sqrtPriceX96 appropriate for the asset pair
///   - _initializeConcreteVaults() (optional) — deploy any vault instances that need the fork
///   - _minSwapAmount() / _maxSwapAmount() (optional) — fuzz bounds for the asset pair
///   - deal(...) (optional)    — override for non-standard tokens (e.g. stETH via Lido)
abstract contract BaseUnderlyingAssetsSwapHookTest is BaseVaultsTest {
    using SafeCast for int256;

    // ── Underlying-assets swap hook infrastructure ────────────────────────────
    UnderlyingAssetsSwapHookFactory public underlyingAssetsFactory;
    UnderlyingAssetsSwapHook public assetSwapHook;
    PoolKey public assetsPoolKey;

    // ── Liquidity added to the vault-wrapper pool for the hook to route through ─
    // Expressed as a Uniswap v4 liquidity unit. Full-range at 1:1 price means each
    // side needs roughly this many token units, so 1e18 gives ~1 ETH of depth per side.
    uint128 constant VAULT_POOL_LIQUIDITY = 10 ** 9;

    // ─────────────────────────────────────────────────────────────────────────
    //  Hooks for concrete subclasses
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Called after the fork is active but before setUpVaults(). Override to deploy
    ///      vault instances that depend on fork state (e.g. SmoothYieldVault with stETH).
    function _initializeConcreteVaults() internal virtual {}

    /// @dev Fuzz lower bound for swap amounts (in asset decimals).
    function _minSwapAmount() internal pure virtual returns (uint256) {
        return 10;
    }

    /// @dev Fuzz upper bound for swap amounts (in asset decimals).
    function _maxSwapAmount() internal pure virtual returns (uint256) {
        return 1e6; // 0.01 token units — safe with VAULT_POOL_LIQUIDITY = 1e18
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public virtual override {
        // 1. Create the mainnet fork and deploy YieldHarvestingHook + support contracts.
        super.setUp();

        // 2. Let concrete subclasses deploy vault instances that need the fork context.
        _initializeConcreteVaults();

        // 3. Create vault wrappers and initialize the vault-wrapper pool (sets poolKey).
        setUpVaults(false);

        // 4. Add liquidity to the vault-wrapper pool so the hook can route through it.
        _addLiquidityToVaultPool();

        // 5. Deploy the UnderlyingAssetsSwapHookFactory and create the hook + asset pool.
        _deployUnderlyingAssetsSwapHook();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Adds full-range liquidity to the vault-wrapper pool (`poolKey`) so that the
    ///      UnderlyingAssetsSwapHook can swap through it during tests.
    function _addLiquidityToVaultPool() internal {
        uint160 sqrtPriceX96 = _getInitialPrice();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
            liquidityDelta: int256(uint256(VAULT_POOL_LIQUIDITY)),
            salt: 0
        });

        modifyLiquidity(params, sqrtPriceX96);
    }

    /// @dev Deploys the factory, mines a valid CREATE2 salt, and creates the hook +
    ///      initializes the raw-asset pool.
    function _deployUnderlyingAssetsSwapHook() internal {
        underlyingAssetsFactory = new UnderlyingAssetsSwapHookFactory(poolManager);

        // poolKey is the vault-wrapper pool key set by setUpVaults() — the factory
        // needs exactly this key so the hook knows which vault-wrapper pool to route through.
        (, bytes32 salt) = underlyingAssetsFactory.findSalt(poolKey);
        (assetSwapHook, assetsPoolKey) = underlyingAssetsFactory.create(poolKey, salt);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Shared swap helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _currencyToIERC20(Currency currency) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(currency));
    }

    function _swapExactIn(uint256 amountIn, bool zeroForOne) internal {
        amountIn = bound(amountIn, _minSwapAmount(), _maxSwapAmount());

        Currency currencyIn = zeroForOne ? assetsPoolKey.currency0 : assetsPoolKey.currency1;
        Currency currencyOut = zeroForOne ? assetsPoolKey.currency1 : assetsPoolKey.currency0;

        // Fund the user and the pool manager (PM needs the tokens before beforeSwap runs).
        deal(Currency.unwrap(currencyIn), address(this), amountIn);
        _currencyToIERC20(currencyIn).approve(address(swapRouter), amountIn);
        deal(Currency.unwrap(currencyIn), address(poolManager), amountIn);

        uint256 balanceBefore = currencyOut.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = swapRouter.swap(
            assetsPoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 amountOut = SafeCast.toUint256(zeroForOne ? delta.amount1() : delta.amount0());
        assertEq(
            amountOut,
            currencyOut.balanceOf(address(this)) - balanceBefore,
            "currencyOut balance mismatch after exact-in swap"
        );
        assertGt(amountOut, 0, "No output from exact-in swap");
    }

    function _swapExactOut(uint256 amountOut, bool zeroForOne) internal {
        amountOut = bound(amountOut, _minSwapAmount(), _maxSwapAmount());

        Currency currencyIn = zeroForOne ? assetsPoolKey.currency0 : assetsPoolKey.currency1;

        // Use 2× the output amount as an upper bound for the input (assumes ~1:1 ratio).
        uint256 maxIn = amountOut * 2;
        deal(Currency.unwrap(currencyIn), address(this), maxIn);
        _currencyToIERC20(currencyIn).approve(address(swapRouter), maxIn);
        deal(Currency.unwrap(currencyIn), address(poolManager), maxIn);

        uint256 balanceBefore = currencyIn.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = swapRouter.swap(
            assetsPoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 amountIn = SafeCast.toUint256(zeroForOne ? -delta.amount0() : -delta.amount1());
        assertEq(
            amountIn,
            balanceBefore - currencyIn.balanceOf(address(this)),
            "currencyIn balance mismatch after exact-out swap"
        );
        assertGt(amountIn, 0, "No input consumed in exact-out swap");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Disable inherited YieldHarvestingHookTest tests
    //
    //  Those tests call setUpVaults() again inside the test function, which
    //  collides with the vault wrappers already deployed by our setUp().
    //  They are covered by EulerVaultsTest / MorphoVaultsTest / etc.
    // ─────────────────────────────────────────────────────────────────────────

    function test_yieldAndHarvestBeforeRemoveLiquidity(uint256, uint256, bool) public override {}

    function test_yieldAndHarvestBeforeSwap(ModifyLiquidityParams memory, uint256, uint256, bool) public override {}

    function test_mixedPoolYieldHarvesting(ModifyLiquidityParams memory, uint256, bool) public override {}

    function testPoolInitializationFailsIfNotFactory(uint160, bool) public override {}

    // ─────────────────────────────────────────────────────────────────────────
    //  Shared tests — run for every concrete subclass
    // ─────────────────────────────────────────────────────────────────────────

    function test_assetSwap_exactIn_zeroForOne(uint256 amountIn) public {
        _swapExactIn(amountIn, true);
    }

    function test_assetSwap_exactIn_oneForZero(uint256 amountIn) public {
        _swapExactIn(amountIn, false);
    }

    function test_assetSwap_exactOut_zeroForOne(uint256 amountOut) public {
        _swapExactOut(amountOut, true);
    }

    function test_assetSwap_exactOut_oneForZero(uint256 amountOut) public {
        _swapExactOut(amountOut, false);
    }

    /// @dev Verify the hook immutables are wired to the correct vault chain.
    function test_hookImmutables_matchVaultChain() public view {
        // asset0 and asset1 are the raw assets of the underlying vaults
        address a0 = address(assetSwapHook.asset0());
        address a1 = address(assetSwapHook.asset1());

        // They must be the raw assets at the bottom of the vault chain
        IERC20 expectedAsset0 = IERC20(assetSwapHook.underlyingVault0().asset());
        IERC20 expectedAsset1 = IERC20(assetSwapHook.underlyingVault1().asset());

        assertEq(a0, address(expectedAsset0));
        assertEq(a1, address(expectedAsset1));

        // The assets pool key currencies must be the sorted raw assets
        address expectedC0 = a0 < a1 ? a0 : a1;
        address expectedC1 = a0 < a1 ? a1 : a0;
        assertEq(Currency.unwrap(assetsPoolKey.currency0), expectedC0);
        assertEq(Currency.unwrap(assetsPoolKey.currency1), expectedC1);
    }

    /// @dev Verify the factory registered the hook correctly.
    function test_factory_hookForPool() public view {
        assertEq(
            address(underlyingAssetsFactory.hookForPool(poolKey.toId())),
            address(assetSwapHook),
            "hookForPool should map the vault-wrapper poolId to the deployed hook"
        );
    }

    /// @dev Verify that adding liquidity directly to the asset pool is blocked.
    function test_assetPool_addLiquidityBlocked() public {
        deal(Currency.unwrap(assetsPoolKey.currency0), address(this), 1e18);
        deal(Currency.unwrap(assetsPoolKey.currency1), address(this), 1e18);
        _currencyToIERC20(assetsPoolKey.currency0).approve(address(modifyLiquidityRouter), type(uint256).max);
        _currencyToIERC20(assetsPoolKey.currency1).approve(address(modifyLiquidityRouter), type(uint256).max);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(assetsPoolKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(assetsPoolKey.tickSpacing),
            liquidityDelta: int256(1e18),
            salt: 0
        });

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(assetsPoolKey, params, "");
    }
}
