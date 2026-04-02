// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IHookEvents} from "src/interfaces/IHookEvents.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice A simplified version of AssetToAssetSwapHookForERC4626 scoped to a single vault wrapper pair.
/// @dev Because the vault wrapper addresses are known at construction time, all token approvals (including
///      Permit2) are set once in the constructor. No per-transaction approval logic or SwapContext needed.
/// @dev Assumes both vault wrappers have an ERC4626 vault as their underlying asset.
/// @dev Can only be attached to a pool by the factory that deployed it (enforced via beforeInitialize).
/// @dev Adding liquidity directly to the asset pool is blocked; liquidity must be added to the underlying
///      vault wrapper pool via the yield harvesting hook.
contract UnderlyingAssetsSwapHook is BaseHook, IHookEvents {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using PoolIdLibrary for PoolKey;

    uint256 public constant Q96_INVERSE_CONSTANT = 2 ** 192;

    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public immutable factory;

    error NotFactory();

    /// @notice The yield harvesting hook that manages the underlying vault wrapper pool
    IHooks public immutable yieldHarvestingHook;

    // ── Vault wrapper layer (tokens living inside the underlying pool) ────────
    IERC4626 public immutable vaultWrapper0;
    IERC4626 public immutable vaultWrapper1;

    // ── Underlying ERC4626 vault layer (asset of each vault wrapper) ─────────
    IERC4626 public immutable underlyingVault0;
    IERC4626 public immutable underlyingVault1;

    // ── Raw asset layer (underlying assets of each underlying vault) ────────────
    // Note: asset0 corresponds to vaultWrapper0 but is NOT necessarily assetsPoolKey.currency0;
    // the asset pool sorts currencies by address independently of the vault wrapper ordering.
    // See isAsset0Currency0 below.
    IERC20 public immutable asset0;
    IERC20 public immutable asset1;

    /// @dev True when address(vaultWrapper0) < address(vaultWrapper1), used to derive
    ///      the correct zeroForOne direction when forwarding the swap to the vault pool.
    bool public immutable isVaultWrapper0LessThanVaultWrapper1;

    /// @dev True when address(asset0) < address(asset1), meaning asset0 == assetsPoolKey.currency0.
    ///      False when the asset pool sorted currencies the other way (asset1 becomes currency0),
    ///      in which case the asset pool's zeroForOne must be flipped before selecting a vault wrapper.
    bool public immutable isAsset0Currency0;

    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    PoolKey private vaultWrapperPoolKey;

    constructor(
        IPoolManager _poolManager,
        IHooks _yieldHarvestingHook,
        IERC4626 _vaultWrapper0,
        IERC4626 _vaultWrapper1,
        uint24 _fee,
        int24 _tickSpacing,
        address _factory
    ) BaseHook(_poolManager) {
        factory = _factory;
        yieldHarvestingHook = _yieldHarvestingHook;

        vaultWrapper0 = _vaultWrapper0;
        vaultWrapper1 = _vaultWrapper1;

        underlyingVault0 = IERC4626(_vaultWrapper0.asset());
        underlyingVault1 = IERC4626(_vaultWrapper1.asset());

        asset0 = IERC20(underlyingVault0.asset());
        asset1 = IERC20(underlyingVault1.asset());

        isVaultWrapper0LessThanVaultWrapper1 = address(_vaultWrapper0) < address(_vaultWrapper1);
        isAsset0Currency0 = address(asset0) < address(asset1);

        fee = _fee;
        tickSpacing = _tickSpacing;

        vaultWrapperPoolKey = PoolKey({
            currency0: isVaultWrapper0LessThanVaultWrapper1
                ? Currency.wrap(address(_vaultWrapper0))
                : Currency.wrap(address(_vaultWrapper1)),
            currency1: isVaultWrapper0LessThanVaultWrapper1
                ? Currency.wrap(address(_vaultWrapper1))
                : Currency.wrap(address(_vaultWrapper0)),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: _yieldHarvestingHook
        });

        // Approve raw assets to Permit2, then grant underlying vaults unlimited Permit2 allowance.
        // Some underlying vaults pull tokens via Permit2 rather than a direct transferFrom.
        asset0.forceApprove(PERMIT2, type(uint256).max);
        asset1.forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2)
            .approve(address(asset0), address(underlyingVault0), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2)
            .approve(address(asset1), address(underlyingVault1), type(uint160).max, type(uint48).max);

        // Also keep a direct ERC20 approval so vaults that do a standard transferFrom still work.
        asset0.forceApprove(address(underlyingVault0), type(uint256).max);
        asset1.forceApprove(address(underlyingVault1), type(uint256).max);

        // Approve vault wrappers to spend underlying vault shares (standard ERC20, no Permit2 needed here because we know they do not pull using Permit2).
        IERC20(address(underlyingVault0)).forceApprove(address(_vaultWrapper0), type(uint256).max);
        IERC20(address(underlyingVault1)).forceApprove(address(_vaultWrapper1), type(uint256).max);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        // Translate the asset pool's zeroForOne into the hook's vault wrapper ordering.
        // vaultWrapper0 holds asset0; if asset0 is currency1 of the asset pool (isAsset0Currency0=false)
        // the direction must be flipped before selecting which vault wrapper is "in" vs "out".
        bool hookZeroForOne = isAsset0Currency0 ? params.zeroForOne : !params.zeroForOne;

        bool vaultPoolZeroForOne = isVaultWrapper0LessThanVaultWrapper1 ? hookZeroForOne : !hookZeroForOne;
        // sqrtPriceLimit needs inversion whenever the vault pool direction differs from the asset pool direction.
        // This happens iff exactly one of the two orderings (asset vs vault wrapper) is flipped.
        uint160 sqrtPriceLimit = (isVaultWrapper0LessThanVaultWrapper1 != isAsset0Currency0)
            ? _invertSqrtPriceX96(params.sqrtPriceLimitX96)
            : params.sqrtPriceLimitX96;

        uint256 amountIn;
        uint256 amountOut;

        if (isExactInput) {
            (amountIn, amountOut) =
                _handleExactInput(hookZeroForOne, vaultPoolZeroForOne, sqrtPriceLimit, params.amountSpecified);
        } else {
            (amountIn, amountOut) =
                _handleExactOutput(hookZeroForOne, vaultPoolZeroForOne, sqrtPriceLimit, params.amountSpecified);
        }

        if (isExactInput) {
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                params.zeroForOne ? amountIn.toInt256().toInt128() : -amountOut.toInt256().toInt128(),
                params.zeroForOne ? -amountOut.toInt256().toInt128() : amountIn.toInt256().toInt128(),
                0,
                0
            );
        } else {
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                params.zeroForOne ? -amountIn.toInt256().toInt128() : amountOut.toInt256().toInt128(),
                params.zeroForOne ? amountOut.toInt256().toInt128() : -amountIn.toInt256().toInt128(),
                0,
                0
            );
        }

        BeforeSwapDelta returnDelta = isExactInput
            ? toBeforeSwapDelta(amountIn.toInt256().toInt128(), -(amountOut.toInt256().toInt128()))
            : toBeforeSwapDelta(-(amountOut.toInt256().toInt128()), amountIn.toInt256().toInt128());

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    function _handleExactInput(
        bool zeroForOne,
        bool vaultPoolZeroForOne,
        uint160 sqrtPriceLimit,
        int256 amountSpecified
    ) private returns (uint256 amountIn, uint256 amountOut) {
        IERC4626 vaultWrapperIn = zeroForOne ? vaultWrapper0 : vaultWrapper1;
        IERC4626 vaultWrapperOut = zeroForOne ? vaultWrapper1 : vaultWrapper0;
        IERC4626 underlyingVaultIn = zeroForOne ? underlyingVault0 : underlyingVault1;
        IERC4626 underlyingVaultOut = zeroForOne ? underlyingVault1 : underlyingVault0;

        amountIn = (-amountSpecified).toUint256();
        uint256 sharesIn = _depositToVaultWrapper(underlyingVaultIn, vaultWrapperIn, amountIn);
        uint256 sharesOut = _swapInVaultPool(vaultPoolZeroForOne, sqrtPriceLimit, sharesIn, true);
        amountOut = _redeemFromVaultWrapper(vaultWrapperOut, underlyingVaultOut, sharesOut);
    }

    function _handleExactOutput(
        bool zeroForOne,
        bool vaultPoolZeroForOne,
        uint160 sqrtPriceLimit,
        int256 amountSpecified
    ) private returns (uint256 amountIn, uint256 amountOut) {
        IERC4626 vaultWrapperIn = zeroForOne ? vaultWrapper0 : vaultWrapper1;
        IERC4626 vaultWrapperOut = zeroForOne ? vaultWrapper1 : vaultWrapper0;
        IERC4626 underlyingVaultIn = zeroForOne ? underlyingVault0 : underlyingVault1;
        IERC4626 underlyingVaultOut = zeroForOne ? underlyingVault1 : underlyingVault0;

        amountOut = amountSpecified.toUint256();
        uint256 sharesNeeded = vaultWrapperOut.previewWithdraw(underlyingVaultOut.previewWithdraw(amountOut));
        uint256 sharesIn = _swapInVaultPool(vaultPoolZeroForOne, sqrtPriceLimit, sharesNeeded, false);
        _redeemFromVaultWrapper(vaultWrapperOut, underlyingVaultOut, sharesNeeded);
        amountIn = _mintVaultWrapper(underlyingVaultIn, vaultWrapperIn, sharesIn);
    }

    // ── Conversion helpers ───────────────────────────────────────────────────

    /// @dev Take raw asset from pool manager, deposit through both vault layers, settle vault wrapper shares.
    function _depositToVaultWrapper(IERC4626 underlyingVault, IERC4626 vaultWrapper, uint256 assetAmount)
        private
        returns (uint256 vaultWrapperShares)
    {
        poolManager.sync(Currency.wrap(address(vaultWrapper)));
        poolManager.take(Currency.wrap(address(IERC20(underlyingVault.asset()))), address(this), assetAmount);
        uint256 underlyingShares = underlyingVault.deposit(assetAmount, address(this));
        vaultWrapperShares = vaultWrapper.deposit(underlyingShares, address(poolManager));
        poolManager.settle();
    }

    /// @dev Take vault wrapper shares from pool manager, redeem through both vault layers, settle raw asset.
    ///      Returns the raw asset amount received.
    function _redeemFromVaultWrapper(IERC4626 vaultWrapper, IERC4626 underlyingVault, uint256 vaultWrapperShares)
        private
        returns (uint256 assetAmount)
    {
        poolManager.sync(Currency.wrap(address(IERC20(underlyingVault.asset()))));
        poolManager.take(Currency.wrap(address(vaultWrapper)), address(this), vaultWrapperShares);
        uint256 underlyingShares = vaultWrapper.redeem(vaultWrapperShares, address(this), address(this));
        assetAmount = underlyingVault.redeem(underlyingShares, address(poolManager), address(this));
        poolManager.settle();
    }

    /// @dev Take raw asset from pool manager, mint the exact number of vault wrapper shares needed, settle.
    ///      Returns the actual raw asset amount consumed.
    function _mintVaultWrapper(IERC4626 underlyingVault, IERC4626 vaultWrapper, uint256 vaultWrapperShares)
        private
        returns (uint256 assetAmount)
    {
        poolManager.sync(Currency.wrap(address(vaultWrapper)));
        uint256 underlyingSharesNeeded = vaultWrapper.previewMint(vaultWrapperShares);
        uint256 estimatedAsset = underlyingVault.previewMint(underlyingSharesNeeded);
        poolManager.take(Currency.wrap(address(IERC20(underlyingVault.asset()))), address(this), estimatedAsset);
        assetAmount = underlyingVault.mint(underlyingSharesNeeded, address(this));
        vaultWrapper.mint(vaultWrapperShares, address(poolManager));
        poolManager.settle();
    }

    // ── Internal vault pool swap ─────────────────────────────────────────────

    function _swapInVaultPool(bool zeroForOne, uint160 sqrtPriceLimitX96, uint256 amount, bool isExactInput)
        private
        returns (uint256 outputAmount)
    {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: isExactInput ? -amount.toInt256() : amount.toInt256(),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BalanceDelta delta = poolManager.swap(vaultWrapperPoolKey, swapParams, "");

        if (isExactInput) {
            outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        } else {
            outputAmount = zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        }
    }

    // ── Utilities ────────────────────────────────────────────────────────────

    function _invertSqrtPriceX96(uint160 x) internal pure returns (uint160 invX) {
        invX = uint160(Q96_INVERSE_CONSTANT / x);
        if (invX <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (invX >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
    }

    function _beforeInitialize(address caller, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (caller != factory) revert NotFactory();
        return this.beforeInitialize.selector;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true, // no adding liquidity allowed! This is a simple helper hook
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
