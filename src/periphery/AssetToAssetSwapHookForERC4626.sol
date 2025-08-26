// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
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
import {IHookEvents} from "src/interfaces/IHookEvents.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EVCUtil} from "ethereum-vault-connector//utils/EVCUtil.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";

interface IPositionManagerExtended is IPositionManager {
    function WETH9() external view returns (address);
}

///@dev This doesn't support aave vaults. Only vault wrappers that have underlying vaults that support ERC4626 interface are supported
///@dev hookData is supposed have two encoded IERC4626 vault wrappers (for token0 and token1 respectively), leave it as address(0) if there is no vault wrapper for that token
contract AssetToAssetSwapHookForERC4626 is EVCUtil, BaseHook, BaseAssetToVaultWrapperHelper, IHookEvents {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    IPositionManager public immutable positionManager;
    /// @notice The hooks contract for vault wrapper pools
    IHooks public immutable yieldHarvestingHook;
    IWETH9 public immutable weth;

    error NotOwner();

    constructor(address _evc, IPoolManager poolManager, IPositionManager _positionManager, IHooks _yieldHarvestingHook)
        EVCUtil(_evc)
        BaseHook(poolManager)
    {
        yieldHarvestingHook = _yieldHarvestingHook;
        positionManager = _positionManager;
        weth = IWETH9(IPositionManagerExtended(address(_positionManager)).WETH9());
    }

    function _modifyLiquidity(
        PoolKey memory poolKey,
        uint8 actionType, // either Actions.MINT_POSITION or Actions.INCREASE_LIQUIDITY
        bytes memory actionData, // encoded params for first action
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal {
        (IERC4626 vaultWrapper0, IERC4626 vaultWrapper1) = abi.decode(hookData, (IERC4626, IERC4626));
        if (amount0Max != 0) {
            if (!poolKey.currency0.isAddressZero()) {
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(_msgSender(), address(this), amount0Max);
            } else if (msg.value == 0) {
                weth.transferFrom(_msgSender(), address(this), amount0Max);
            }
        }
        if (amount1Max != 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(_msgSender(), address(this), amount1Max);
        }

        uint256 currentWETHBalance = weth.balanceOf(address(this));
        if (currentWETHBalance > 0) {
            weth.withdraw(currentWETHBalance);
        }

        amount0Max = SafeCast.toUint128(poolKey.currency0.balanceOf(address(this)));
        amount1Max = SafeCast.toUint128(poolKey.currency1.balanceOf(address(this)));

        if (address(vaultWrapper0) != address(0)) {
            IERC4626 underlyingVault0 = _getUnderlyingVault(vaultWrapper0);
            _deposit(
                vaultWrapper0,
                address(underlyingVault0),
                IERC20(Currency.unwrap(poolKey.currency0)),
                address(this),
                amount0Max,
                address(positionManager)
            );
            poolKey.currency0 = Currency.wrap(address(vaultWrapper0));
            poolKey.hooks = yieldHarvestingHook;
        } else {
            if (!poolKey.currency0.isAddressZero()) {
                poolKey.currency0.transfer(address(positionManager), amount0Max);
            }
        }

        if (address(vaultWrapper1) != address(0)) {
            IERC4626 underlyingVault1 = _getUnderlyingVault(vaultWrapper1);
            _deposit(
                vaultWrapper1,
                address(underlyingVault1),
                IERC20(Currency.unwrap(poolKey.currency1)),
                address(this),
                amount1Max,
                address(positionManager)
            );
            poolKey.currency1 = Currency.wrap(address(vaultWrapper1));
            poolKey.hooks = yieldHarvestingHook;
        } else {
            poolKey.currency1.transfer(address(positionManager), amount1Max);
        }

        //currencies might be out of order at this point, so we need to sort them
        if (Currency.unwrap(poolKey.currency0) > Currency.unwrap(poolKey.currency1)) {
            (poolKey.currency0, poolKey.currency1) = (poolKey.currency1, poolKey.currency0);
        }

        bytes memory actions = new bytes(5);
        actions[0] = bytes1(actionType);
        actions[1] = bytes1(uint8(Actions.SETTLE));
        actions[2] = bytes1(uint8(Actions.SETTLE));
        actions[3] = bytes1(uint8(Actions.SWEEP));
        actions[4] = bytes1(uint8(Actions.SWEEP));

        bytes[] memory params = new bytes[](5);
        params[0] = actionData;
        params[1] = abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false);
        params[3] = abi.encode(poolKey.currency0, _msgSender());
        params[4] = abi.encode(poolKey.currency1, _msgSender());

        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp);
    }

    function mintPosition(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) external payable returns (uint256 tokenId) {
        tokenId = positionManager.nextTokenId();

        bytes memory actionData =
            abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, "");

        _modifyLiquidity(poolKey, uint8(Actions.MINT_POSITION), actionData, amount0Max, amount1Max, hookData);
    }

    function increaseLiquidity(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) external payable {
        //it is expected that the user has approved tokenId to this contract, otherwise increasing liquidity on behalf of someone else is not allowed
        if (IERC721(address(positionManager)).ownerOf(tokenId) != _msgSender()) {
            revert NotOwner();
        }
        bytes memory actionData = abi.encode(tokenId, liquidity, amount0Max, amount1Max, "");
        _modifyLiquidity(poolKey, uint8(Actions.INCREASE_LIQUIDITY), actionData, amount0Max, amount1Max, hookData);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
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
        } else {
            (amountIn, amountOut) = _handleExactOutputSwap(context, params);
        }

        BeforeSwapDelta returnDelta = _calculateReturnDelta(isExactInput, amountIn, amountOut);

        //TODO: emit HookSwap event

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

    function _getUnderlyingVault(IERC4626 vaultWrapper) internal view returns (IERC4626 underlyingVault) {
        try vaultWrapper.asset() returns (address asset) {
            underlyingVault = IERC4626(asset);
        } catch {
            underlyingVault = IERC4626(address(0));
        }
        return underlyingVault;
    }

    /// @dev Initialize swap context with vault wrappers and assets
    function _initializeSwapContext(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        private
        view
        returns (SwapContext memory context)
    {
        (IERC4626 vaultWrapper0, IERC4626 vaultWrapper1) = abi.decode(hookData, (IERC4626, IERC4626));

        IERC4626 underlyingVault0 = _getUnderlyingVault(vaultWrapper0);
        IERC4626 underlyingVault1 = _getUnderlyingVault(vaultWrapper1);

        try vaultWrapper1.asset() returns (address asset1) {
            underlyingVault1 = IERC4626(asset1);
        } catch {
            underlyingVault1 = IERC4626(address(0));
        }

        (context.vaultWrapperIn, context.vaultWrapperOut) =
            params.zeroForOne ? (vaultWrapper0, vaultWrapper1) : (vaultWrapper1, vaultWrapper0);

        (context.underlyingVaultIn, context.underlyingVaultOut) =
            params.zeroForOne ? (underlyingVault0, underlyingVault1) : (underlyingVault1, underlyingVault0);

        context.assetIn =
            params.zeroForOne ? IERC20(Currency.unwrap(key.currency0)) : IERC20(Currency.unwrap(key.currency1));
        context.assetOut =
            params.zeroForOne ? IERC20(Currency.unwrap(key.currency1)) : IERC20(Currency.unwrap(key.currency0));

        context.vaultWrapperPoolKey = PoolKey({
            currency0: address(vaultWrapper0) < address(vaultWrapper1)
                ? Currency.wrap(address(vaultWrapper0))
                : Currency.wrap(address(vaultWrapper1)),
            currency1: address(vaultWrapper0) < address(vaultWrapper1)
                ? Currency.wrap(address(vaultWrapper1))
                : Currency.wrap(address(vaultWrapper0)),
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
