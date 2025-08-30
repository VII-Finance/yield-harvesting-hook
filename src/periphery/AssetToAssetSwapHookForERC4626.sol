// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IHookEvents} from "src/interfaces/IHookEvents.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {EVCUtil, LiquidityHelper} from "src/periphery/LiquidityHelper.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {BaseAssetToVaultWrapperHelper} from "src/periphery/base/BaseAssetToVaultWrapperHelper.sol";

/// @notice This contract enables users to interact with pools created using the yield harvesting hook without needing to manually convert assets to or from vault wrappers.
/// @dev It automates the conversion between ERC20 assets without any special logic, following the flow described in https://github.com/VII-Finance/yield-harvesting-hook/blob/periphery-contracts/docs/swap_flow.md.
/// @dev Only vault wrappers with underlying vaults that support the ERC4626 interface are supported; Aave vaults are not supported.
/// @dev hookData should contain two encoded IERC4626 vault wrappers (for token0 and token1 respectively), or address(0) if no vault wrapper is used for that token
/// @dev if hookDat is not provided then default vault wrappers decided by the hook owner will be used.
contract AssetToAssetSwapHookForERC4626 is BaseHook, BaseAssetToVaultWrapperHelper, Ownable, IHookEvents {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    struct VaultWrappers {
        IERC4626 vaultWrapperForCurrency0;
        IERC4626 vaultWrapperForCurrency1;
    }

    /// @notice The hooks contract for vault wrapper pools
    IHooks public immutable yieldHarvestingHook;

    mapping(PoolId poolId => VaultWrappers vaultWrappers) public defaultVaultWrappers;

    event DefaultVaultWrappersSet(
        bytes32 indexed poolId, address indexed vaultWrappers0, address indexed vaultWrapperForCurrency1
    );

    constructor(IPoolManager _poolManager, IHooks _yieldHarvestingHook, address _initialOwner)
        BaseHook(_poolManager)
        Ownable(_initialOwner)
    {
        yieldHarvestingHook = _yieldHarvestingHook;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        SwapContext memory context = _initializeSwapContext(key, params, hookData);

        uint256 amountIn;
        uint256 amountOut;

        if (isExactInput) {
            (amountIn, amountOut) = _handleExactInputSwap(context, params);

            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                params.zeroForOne ? amountIn.toInt256().toInt128() : -amountOut.toInt256().toInt128(),
                params.zeroForOne ? -amountOut.toInt256().toInt128() : amountIn.toInt256().toInt128(),
                0,
                0
            );
        } else {
            (amountIn, amountOut) = _handleExactOutputSwap(context, params);

            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                params.zeroForOne ? -amountIn.toInt256().toInt128() : amountOut.toInt256().toInt128(),
                params.zeroForOne ? amountOut.toInt256().toInt128() : -amountIn.toInt256().toInt128(),
                0,
                0
            );
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
    function _initializeSwapContext(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        private
        view
        returns (SwapContext memory context)
    {
        IERC4626 vaultWrapperForCurrency0;
        IERC4626 vaultWrapperForCurrency1;

        //if vault wrappers to use is not provided than the contract will simply use defaults set by owner
        if (hookData.length > 0) {
            (vaultWrapperForCurrency0, vaultWrapperForCurrency1) = abi.decode(hookData, (IERC4626, IERC4626));
        } else {
            VaultWrappers memory defaultVaultWrappersSetByOwner = defaultVaultWrappers[key.toId()];
            (vaultWrapperForCurrency0, vaultWrapperForCurrency1) = (
                defaultVaultWrappersSetByOwner.vaultWrapperForCurrency0,
                defaultVaultWrappersSetByOwner.vaultWrapperForCurrency1
            );
        }

        IERC4626 underlyingVault0 = _getUnderlyingVault(vaultWrapperForCurrency0);
        IERC4626 underlyingVault1 = _getUnderlyingVault(vaultWrapperForCurrency1);

        try vaultWrapperForCurrency1.asset() returns (address asset1) {
            underlyingVault1 = IERC4626(asset1);
        } catch {
            underlyingVault1 = IERC4626(address(0));
        }

        (context.vaultWrapperIn, context.vaultWrapperOut) = params.zeroForOne
            ? (vaultWrapperForCurrency0, vaultWrapperForCurrency1)
            : (vaultWrapperForCurrency1, vaultWrapperForCurrency0);

        (context.underlyingVaultIn, context.underlyingVaultOut) =
            params.zeroForOne ? (underlyingVault0, underlyingVault1) : (underlyingVault1, underlyingVault0);

        context.assetIn =
            params.zeroForOne ? IERC20(Currency.unwrap(key.currency0)) : IERC20(Currency.unwrap(key.currency1));
        context.assetOut =
            params.zeroForOne ? IERC20(Currency.unwrap(key.currency1)) : IERC20(Currency.unwrap(key.currency0));

        context.vaultWrapperPoolKey = PoolKey({
            currency0: address(vaultWrapperForCurrency0) < address(vaultWrapperForCurrency1)
                ? Currency.wrap(address(vaultWrapperForCurrency0))
                : Currency.wrap(address(vaultWrapperForCurrency1)),
            currency1: address(vaultWrapperForCurrency0) < address(vaultWrapperForCurrency1)
                ? Currency.wrap(address(vaultWrapperForCurrency1))
                : Currency.wrap(address(vaultWrapperForCurrency0)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: yieldHarvestingHook
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

    function setDefaultVaultWrappers(
        PoolKey memory assetsPoolKey,
        IERC4626 vaultWrapperForCurrency0,
        IERC4626 vaultWrapperForCurrency1
    ) external onlyOwner {
        //we expect owner to make sure they sanity check the addresses
        //address(0) if we expect currency itself to be used without any vaultWrappers
        PoolId assetsPoolId = assetsPoolKey.toId();
        defaultVaultWrappers[assetsPoolId] = VaultWrappers({
            vaultWrapperForCurrency0: vaultWrapperForCurrency0,
            vaultWrapperForCurrency1: vaultWrapperForCurrency1
        });

        emit DefaultVaultWrappersSet(
            PoolId.unwrap(assetsPoolId), address(vaultWrapperForCurrency0), address(vaultWrapperForCurrency1)
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
}
