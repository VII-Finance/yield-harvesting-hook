// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20, ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {BaseAssetToVaultWrapperHelper} from "src/periphery/Base/BaseAssetToVaultWrapperHelper.sol";

contract AssetToAssetSwapHook is BaseHook, BaseAssetToVaultWrapperHelper {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    /// @notice The vault wrapper for currency0
    IERC4626 public immutable vaultWrapper0;

    /// @notice The vault wrapper for currency1
    IERC4626 public immutable vaultWrapper1;

    IERC4626 public immutable underlyingVault0;

    IERC4626 public immutable underlyingVault1;

    /// @notice The hooks contract for vault wrapper pools
    IHooks public immutable hooks;

    constructor(IPoolManager poolManager, IERC4626 _vaultWrapper0, IERC4626 _vaultWrapper1, IHooks _hooks)
        BaseHook(poolManager)
    {
        vaultWrapper0 = _vaultWrapper0;
        vaultWrapper1 = _vaultWrapper1;
        try _vaultWrapper0.asset() returns (address asset0) {
            underlyingVault0 = IERC4626(asset0);
        } catch {
            underlyingVault0 = IERC4626(address(0));
        }
        try _vaultWrapper1.asset() returns (address asset1) {
            underlyingVault1 = IERC4626(asset1);
        } catch {
            underlyingVault1 = IERC4626(address(0));
        }
        hooks = _hooks;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        SwapContext memory context = _initializeSwapContext(key, params);

        uint256 amountIn;
        uint256 amountOut;

        if (isExactInput) {
            (amountIn, amountOut) = _handleExactInputSwap(context, params);
        } else {
            (amountIn, amountOut) = _handleExactOutputSwap(context, params);
        }

        BeforeSwapDelta returnDelta = _calculateReturnDelta(isExactInput, amountIn, amountOut);
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /// @dev Struct to hold swap context data
    struct SwapContext {
        IERC4626 vaultWrapperIn;
        IERC4626 vaultWrapperOut;
        IERC4626 underlyingVaultIn;
        IERC4626 underlyingVaultOut;
        IERC20 assetIn;
        IERC20 assetOut;
        PoolKey vaultWrapperPoolKey;
    }

    /// @dev Initialize swap context with vault wrappers and assets
    function _initializeSwapContext(PoolKey calldata key, SwapParams calldata params)
        private
        view
        returns (SwapContext memory context)
    {
        (context.vaultWrapperIn, context.vaultWrapperOut) =
            params.zeroForOne ? (vaultWrapper0, vaultWrapper1) : (vaultWrapper1, vaultWrapper0);

        (context.underlyingVaultIn, context.underlyingVaultOut) =
            params.zeroForOne ? (underlyingVault0, underlyingVault1) : (underlyingVault1, underlyingVault0);

        context.assetIn =
            params.zeroForOne ? IERC20(Currency.unwrap(key.currency0)) : IERC20(Currency.unwrap(key.currency1));
        context.assetOut =
            params.zeroForOne ? IERC20(Currency.unwrap(key.currency1)) : IERC20(Currency.unwrap(key.currency0));

        context.vaultWrapperPoolKey = PoolKey({
            currency0: Currency.wrap(address(vaultWrapper0)),
            currency1: Currency.wrap(address(vaultWrapper1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: hooks
        });
    }

    /// @dev Handle exact input swap: user specifies input amount, gets variable output
    function _handleExactInputSwap(SwapContext memory context, SwapParams calldata params)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        amountIn = (-params.amountSpecified).toUint256();

        // Take input tokens from pool manager
        poolManager.take(Currency.wrap(address(context.assetIn)), address(this), amountIn);

        // Convert input asset to vault wrapper shares and send to the PoolManager
        uint256 vaultWrapperSharesMinted =
            _convertAssetToVaultWrapper(context.assetIn, context.underlyingVaultIn, context.vaultWrapperIn, amountIn);

        // Swap vault wrapper shares
        uint256 vaultWrapperOutAmount = _performVaultWrapperSwap(
            context.vaultWrapperPoolKey,
            params,
            vaultWrapperSharesMinted,
            true // isExactInput
        );

        // Take output vault wrapper shares from pool manager
        poolManager.take(Currency.wrap(address(context.vaultWrapperOut)), address(this), vaultWrapperOutAmount);

        // Convert vault wrapper shares to output asset
        amountOut = _convertVaultWrapperToAsset(
            context.vaultWrapperOut, context.underlyingVaultOut, context.assetOut, vaultWrapperOutAmount
        );
    }

    /// @dev Handle exact output swap: user specifies output amount, pays variable input
    function _handleExactOutputSwap(SwapContext memory context, SwapParams calldata params)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        amountOut = params.amountSpecified.toUint256();

        // Calculate required vault wrapper shares for desired output
        uint256 underlyingVaultSharesNeeded = context.underlyingVaultOut.previewWithdraw(amountOut);
        uint256 vaultWrapperSharesNeeded = context.vaultWrapperOut.previewWithdraw(underlyingVaultSharesNeeded);

        // Perform swap to get required vault wrapper shares
        uint256 vaultWrapperInAmount = _performVaultWrapperSwap(
            context.vaultWrapperPoolKey,
            params,
            vaultWrapperSharesNeeded,
            false // isExactInput = false
        );

        // Take the vault wrapper shares obtained from swap
        poolManager.take(Currency.wrap(address(context.vaultWrapperOut)), address(this), vaultWrapperSharesNeeded);

        // output assets are withdrawn from vaultWrapperOut and sent to the poolManager so that the original swapper can take it out
        _withdrawVaultWrapperToAsset(
            context.vaultWrapperOut, context.underlyingVaultOut, context.assetOut, vaultWrapperSharesNeeded, amountOut
        );

        // Calculate input amount needed
        uint256 underlyingVaultSharesNeedIn = context.vaultWrapperIn.previewMint(vaultWrapperInAmount);
        amountIn = context.underlyingVaultIn.previewMint(underlyingVaultSharesNeedIn);

        // Take input from pool manager and mint vault wrapper shares
        poolManager.take(Currency.wrap(address(context.assetIn)), address(this), amountIn);

        //vault wrapperIn tokens are minted and settled
        _mintVaultWrapperShares(
            context.assetIn, context.underlyingVaultIn, context.vaultWrapperIn, amountIn, vaultWrapperInAmount
        );
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
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

    /// @dev Calculate the return delta for the swap
    function _calculateReturnDelta(bool isExactInput, uint256 amountIn, uint256 amountOut)
        private
        pure
        returns (BeforeSwapDelta)
    {
        return isExactInput
            ? toBeforeSwapDelta(amountIn.toInt256().toInt128(), -(amountOut.toInt256().toInt128()))
            : toBeforeSwapDelta(-(amountOut.toInt256().toInt128()), amountIn.toInt256().toInt128());
    }

    /// @dev Convert input asset to vault wrapper shares
    function _convertAssetToVaultWrapper(
        IERC20 asset,
        IERC4626 underlyingVault,
        IERC4626 vaultWrapper,
        uint256 assetAmount
    ) private returns (uint256 vaultWrapperShares) {
        poolManager.sync(Currency.wrap(address(vaultWrapper)));
        if (address(vaultWrapper) != address(asset)) {
            vaultWrapperShares = _deposit(
                vaultWrapper, address(underlyingVault), asset, address(this), assetAmount, address(poolManager)
            );
        } else {
            vaultWrapperShares = assetAmount;
            SafeERC20.safeTransfer(asset, address(poolManager), assetAmount);
        }
        poolManager.settle();
    }

    /// @dev Perform vault wrapper swap
    function _performVaultWrapperSwap(
        PoolKey memory poolKey,
        SwapParams calldata originalParams,
        uint256 amount,
        bool isExactInput
    ) private returns (uint256 outputAmount) {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: originalParams.zeroForOne,
            amountSpecified: isExactInput ? -amount.toInt256() : amount.toInt256(),
            sqrtPriceLimitX96: originalParams.sqrtPriceLimitX96
        });

        BalanceDelta swapDelta = poolManager.swap(poolKey, swapParams, "");

        if (isExactInput) {
            outputAmount =
                originalParams.zeroForOne ? (swapDelta.amount1()).toUint256() : (swapDelta.amount0()).toUint256();
        } else {
            outputAmount =
                originalParams.zeroForOne ? (-swapDelta.amount0()).toUint256() : (-swapDelta.amount1()).toUint256();
        }
    }

    /// @dev Convert vault wrapper shares to output asset
    function _convertVaultWrapperToAsset(
        IERC4626 vaultWrapper,
        IERC4626 underlyingVault,
        IERC20 asset,
        uint256 vaultWrapperAmount
    ) private returns (uint256 assetAmount) {
        poolManager.sync(Currency.wrap(address(asset)));
        if (address(vaultWrapper) != address(asset)) {
            assetAmount =
                _redeem(vaultWrapper, address(underlyingVault), address(this), vaultWrapperAmount, address(poolManager));
        } else {
            // Transfer asset to the poolManager
            SafeERC20.safeTransfer(asset, address(poolManager), vaultWrapperAmount);
            assetAmount = vaultWrapperAmount;
        }
        poolManager.settle();
    }

    /// @dev Mint vault wrapper shares for exact output swaps
    function _mintVaultWrapperShares(
        IERC20 asset,
        IERC4626 underlyingVault,
        IERC4626 vaultWrapper,
        uint256 assetAmount,
        uint256 vaultWrapperAmount
    ) private {
        poolManager.sync(Currency.wrap(address(vaultWrapper)));

        if (address(underlyingVault) != address(vaultWrapper)) {
            _mint(
                vaultWrapper, address(underlyingVault), asset, address(this), vaultWrapperAmount, address(poolManager)
            );
        } else {
            SafeERC20.safeTransfer(asset, address(poolManager), assetAmount);
        }
        poolManager.settle();
    }

    /// @dev Withdraw vault wrapper shares to asset for exact output swaps
    function _withdrawVaultWrapperToAsset(
        IERC4626 vaultWrapper,
        IERC4626 underlyingVault,
        IERC20 asset,
        uint256 vaultWrapperSharesNeeded,
        uint256 amountOut
    ) private {
        poolManager.sync(Currency.wrap(address(asset)));

        if (address(vaultWrapper) != address(asset)) {
            _withdraw(
                vaultWrapper, address(underlyingVault), address(this), vaultWrapperSharesNeeded, address(poolManager)
            );
        } else {
            SafeERC20.safeTransfer(asset, address(poolManager), amountOut);
        }
        poolManager.settle();
    }
}
