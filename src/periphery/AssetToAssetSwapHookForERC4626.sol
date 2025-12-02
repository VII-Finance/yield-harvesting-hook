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
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @notice This contract enables users to interact with pools created using the yield harvesting hook without needing to manually convert assets to or from vault wrappers.
/// @dev It automates the conversion between ERC20 assets without any special logic, following the flow described in https://github.com/VII-Finance/yield-harvesting-hook/blob/periphery-contracts/docs/swap_flow.md.
/// @dev Only vault wrappers with underlying vaults that support the ERC4626 interface are supported; Aave vaults are not supported.
/// @dev hookData should contain two encoded IERC4626 vault wrappers (for token0 and token1 respectively), or address(0) if no vault wrapper is used for that token
/// @dev if hookDat is not provided then default vault wrappers decided by the hook owner will be used.
contract AssetToAssetSwapHookForERC4626 is
    BaseHook,
    BaseAssetToVaultWrapperHelper,
    Ownable,
    IHookEvents,
    IUnlockCallback
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    struct VaultWrappers {
        IERC4626 vaultWrapperForCurrency0;
        IERC4626 vaultWrapperForCurrency1;
    }

    uint256 public constant Q96_INVERSE_CONSTANT = 2 ** 192;

    /// @notice The hooks contract for vault wrapper pools
    IHooks public immutable yieldHarvestingHook;

    mapping(PoolId poolId => VaultWrappers vaultWrappers) public defaultVaultWrappers;
    mapping(address user => mapping(IERC4626 vaultWrapper => uint256 warmLiquidity)) public warmLiquidityBalances;
    mapping(IERC4626 vaultWrapper => uint256 totalWarmLiquidity) public totalWarmLiquidity;

    event DefaultVaultWrappersSet(
        bytes32 indexed poolId, address indexed vaultWrappers0, address indexed vaultWrapperForCurrency1
    );
    event WarmLiquidityAdded(address indexed user, IERC4626 indexed vaultWrapper, uint256 assetAmount);
    event WarmLiquidityRemoved(address indexed user, IERC4626 indexed vaultWrapper, uint256 assetAmount);

    error InsufficientWarmLiquidity(uint256 requested, uint256 available);
    error ZeroAmountNotAllowed();

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

    function invertSqrtPriceX96(uint160 x) internal pure returns (uint160 invX) {
        invX = uint160(Q96_INVERSE_CONSTANT / x);
        if (invX <= TickMath.MIN_SQRT_PRICE) {
            return TickMath.MIN_SQRT_PRICE + 1;
        }
        if (invX >= TickMath.MAX_SQRT_PRICE) {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
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
        bool isVaultForCurrency0LessThanVaultForCurrency1;
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
            (vaultWrapperForCurrency0, vaultWrapperForCurrency1) =
            (
                defaultVaultWrappersSetByOwner.vaultWrapperForCurrency0,
                defaultVaultWrappersSetByOwner.vaultWrapperForCurrency1
            );
        }

        IERC4626 underlyingVault0 = _getUnderlyingVault(vaultWrapperForCurrency0);
        IERC4626 underlyingVault1 = _getUnderlyingVault(vaultWrapperForCurrency1);

        context.isVaultForCurrency0LessThanVaultForCurrency1 =
            address(vaultWrapperForCurrency0) < address(vaultWrapperForCurrency1);

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

        // Convert input asset to vault wrapper shares and send to the PoolManager
        uint256 vaultWrapperSharesMinted =
            _convertAssetToVaultWrapper(context.assetIn, context.underlyingVaultIn, context.vaultWrapperIn, amountIn);

        // Swap vault wrapper shares
        uint256 vaultWrapperOutAmount = _performVaultWrapperSwap(
            context.vaultWrapperPoolKey,
            context.isVaultForCurrency0LessThanVaultForCurrency1 ? params.zeroForOne : !params.zeroForOne,
            context.isVaultForCurrency0LessThanVaultForCurrency1
                ? params.sqrtPriceLimitX96
                : invertSqrtPriceX96(params.sqrtPriceLimitX96),
            vaultWrapperSharesMinted,
            true // isExactInput
        );

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

        uint256 vaultWrapperSharesNeeded;
        if (address(context.assetOut) != address(context.vaultWrapperOut)) {
            // Calculate required vault wrapper shares for desired output
            uint256 underlyingVaultSharesNeeded = context.underlyingVaultOut.previewWithdraw(amountOut);
            vaultWrapperSharesNeeded = context.vaultWrapperOut.previewWithdraw(underlyingVaultSharesNeeded);
        } else {
            // there is no need for conversion if assetOut is same as vaultWrapperOut
            vaultWrapperSharesNeeded = amountOut;
        }

        // Perform swap to get required vault wrapper shares
        uint256 vaultWrapperInAmount = _performVaultWrapperSwap(
            context.vaultWrapperPoolKey,
            context.isVaultForCurrency0LessThanVaultForCurrency1 ? params.zeroForOne : !params.zeroForOne,
            context.isVaultForCurrency0LessThanVaultForCurrency1
                ? params.sqrtPriceLimitX96
                : invertSqrtPriceX96(params.sqrtPriceLimitX96),
            vaultWrapperSharesNeeded,
            false // isExactInput = false
        );

        // output assets are withdrawn from vaultWrapperOut and sent to the poolManager so that the original swapper can take it out
        _withdrawVaultWrapperToAsset(
            context.vaultWrapperOut, context.underlyingVaultOut, context.assetOut, vaultWrapperSharesNeeded, amountOut
        );

        //vault wrapperIn tokens are minted and settled
        amountIn = _mintVaultWrapperShares(
            context.assetIn, context.underlyingVaultIn, context.vaultWrapperIn, vaultWrapperInAmount
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
            vaultWrapperShares = vaultWrapper.previewDeposit(underlyingVault.previewDeposit(assetAmount));
            //if this address has sufficient claims from warmLiquidity then skip the deposit
            if (vaultWrapperShares > poolManager.balanceOf(address(this), Currency.wrap(address(vaultWrapper)).toId()))
            {
                poolManager.take(Currency.wrap(address(asset)), address(this), assetAmount);
                vaultWrapperShares = _deposit(
                    vaultWrapper, address(underlyingVault), asset, address(this), assetAmount, address(poolManager)
                );
            } else {
                //burn the claims
                poolManager.burn(address(this), Currency.wrap(address(vaultWrapper)).toId(), vaultWrapperShares);
                poolManager.mint(address(this), Currency.wrap(address(asset)).toId(), assetAmount);
            }
        } else {
            vaultWrapperShares = assetAmount;
        }
        poolManager.settle();
    }

    /// @dev Perform vault wrapper swap
    function _performVaultWrapperSwap(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96,
        uint256 amount,
        bool isExactInput
    ) private returns (uint256 outputAmount) {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: isExactInput ? -amount.toInt256() : amount.toInt256(),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BalanceDelta swapDelta = poolManager.swap(poolKey, swapParams, "");

        if (isExactInput) {
            outputAmount = zeroForOne ? (swapDelta.amount1()).toUint256() : (swapDelta.amount0()).toUint256();
        } else {
            outputAmount = zeroForOne ? (-swapDelta.amount0()).toUint256() : (-swapDelta.amount1()).toUint256();
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
            assetAmount = underlyingVault.previewRedeem(vaultWrapper.previewRedeem(vaultWrapperAmount));
            //if this address has sufficient claims from warmLiquidity then skip the redeem
            if (assetAmount > poolManager.balanceOf(address(this), Currency.wrap(address(asset)).toId())) {
                poolManager.take(Currency.wrap(address(vaultWrapper)), address(this), vaultWrapperAmount);
                assetAmount = _redeem(
                    vaultWrapper, address(underlyingVault), address(this), vaultWrapperAmount, address(poolManager)
                );
            } else {
                //directly burn the claims from this address
                poolManager.burn(address(this), Currency.wrap(address(asset)).toId(), assetAmount);
                poolManager.mint(address(this), Currency.wrap(address(vaultWrapper)).toId(), vaultWrapperAmount);
            }
        } else {
            assetAmount = vaultWrapperAmount;
        }
        poolManager.settle();
    }

    /// @dev Mint vault wrapper shares for exact output swaps
    function _mintVaultWrapperShares(
        IERC20 asset,
        IERC4626 underlyingVault,
        IERC4626 vaultWrapper,
        uint256 vaultWrapperAmount
    ) internal returns (uint256 assetAmount) {
        poolManager.sync(Currency.wrap(address(vaultWrapper)));

        if (address(asset) != address(vaultWrapper)) {
            //if this address has sufficient claims from warmLiquidity then skip the mint
            assetAmount = underlyingVault.previewMint(vaultWrapper.previewMint(vaultWrapperAmount));

            if (vaultWrapperAmount > poolManager.balanceOf(address(this), Currency.wrap(address(vaultWrapper)).toId()))
            {
                poolManager.take(Currency.wrap(address(asset)), address(this), assetAmount);
                assetAmount = _mint(
                    vaultWrapper,
                    address(underlyingVault),
                    asset,
                    address(this),
                    vaultWrapperAmount,
                    address(poolManager)
                );
            } else {
                //burn the claims
                poolManager.burn(address(this), Currency.wrap(address(vaultWrapper)).toId(), vaultWrapperAmount);
                poolManager.mint(address(this), Currency.wrap(address(asset)).toId(), assetAmount);
            }
        } else {
            assetAmount = vaultWrapperAmount;
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
            if (amountOut > poolManager.balanceOf(address(this), Currency.wrap(address(asset)).toId())) {
                poolManager.take(Currency.wrap(address(vaultWrapper)), address(this), vaultWrapperSharesNeeded);
                _redeem(
                    vaultWrapper,
                    address(underlyingVault),
                    address(this),
                    vaultWrapperSharesNeeded,
                    address(poolManager)
                );
            } else {
                //burn the claims
                poolManager.burn(address(this), Currency.wrap(address(asset)).toId(), amountOut);
                poolManager.mint(address(this), Currency.wrap(address(vaultWrapper)).toId(), vaultWrapperSharesNeeded);
            }
        } else {}
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
            vaultWrapperForCurrency0: vaultWrapperForCurrency0, vaultWrapperForCurrency1: vaultWrapperForCurrency1
        });

        emit DefaultVaultWrappersSet(
            PoolId.unwrap(assetsPoolId), address(vaultWrapperForCurrency0), address(vaultWrapperForCurrency1)
        );
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address user, bool isAddWarmLiquidity, IERC4626 vaultWrapper, uint256 assetAmount) =
            abi.decode(data, (address, bool, IERC4626, uint256));

        IERC4626 underlyingVault = IERC4626(vaultWrapper.asset());
        IERC20 asset = IERC20(underlyingVault.asset());

        if (isAddWarmLiquidity) {
            if (assetAmount > 0) _addWarmLiquidity(user, vaultWrapper, underlyingVault, asset, assetAmount);
            else _rebalance(vaultWrapper, underlyingVault, asset);
        } else {
            _removeWarmLiquidity(user, vaultWrapper, underlyingVault, asset, assetAmount);
        }
    }

    //the amount when adding means the assets but when removing means the vaultWrapper shares
    function _addWarmLiquidity(
        address user,
        IERC4626 vaultWrapper,
        IERC4626 underlyingVault,
        IERC20 asset,
        uint256 assetAmount
    ) internal {
        SafeERC20.safeTransferFrom(asset, user, address(this), assetAmount);

        poolManager.sync(Currency.wrap(address(vaultWrapper)));
        uint256 assetsSpent =
            _mint(vaultWrapper, address(underlyingVault), asset, address(this), assetAmount / 2, address(poolManager));
        poolManager.mint(address(this), Currency.wrap(address(vaultWrapper)).toId(), assetAmount / 2);
        poolManager.settle();

        poolManager.sync(Currency.wrap(address(asset)));
        poolManager.mint(address(this), Currency.wrap(address(asset)).toId(), assetAmount - assetsSpent);
        SafeERC20.safeTransfer(asset, address(poolManager), assetAmount - assetsSpent);
        poolManager.settle();

        warmLiquidityBalances[user][vaultWrapper] += assetAmount;
        totalWarmLiquidity[vaultWrapper] += assetAmount;

        emit WarmLiquidityAdded(user, vaultWrapper, assetAmount);
    }

    function _removeWarmLiquidity(
        address user,
        IERC4626 vaultWrapper,
        IERC4626 underlyingVault,
        IERC20 asset,
        uint256 assetAmount
    ) internal {
        uint256 userWarmLiquidity = warmLiquidityBalances[user][vaultWrapper];
        if (userWarmLiquidity < assetAmount) {
            revert InsufficientWarmLiquidity(assetAmount, userWarmLiquidity);
        }

        poolManager.take(Currency.wrap(address(vaultWrapper)), address(this), assetAmount / 2);
        poolManager.burn(address(this), Currency.wrap(address(vaultWrapper)).toId(), assetAmount / 2);

        uint256 assetsReceived = _redeem(vaultWrapper, address(underlyingVault), address(this), assetAmount / 2, user);

        poolManager.take(Currency.wrap(address(asset)), user, assetsReceived);
        poolManager.burn(address(this), Currency.wrap(address(asset)).toId(), assetsReceived);

        warmLiquidityBalances[user][vaultWrapper] -= assetAmount;
        totalWarmLiquidity[vaultWrapper] -= assetAmount;

        emit WarmLiquidityRemoved(user, vaultWrapper, assetAmount);
    }

    function _rebalance(IERC4626 vaultWrapper, IERC4626 underlyingVault, IERC20 asset) internal {
        uint256 totalWarmLiquidityForVaultWrapper = totalWarmLiquidity[vaultWrapper];

        uint256 currentVaultWrapperBalance =
            poolManager.balanceOf(address(this), Currency.wrap(address(vaultWrapper)).toId());
        uint256 desiredVaultWrapperBalance = totalWarmLiquidityForVaultWrapper / 2;

        if (currentVaultWrapperBalance < desiredVaultWrapperBalance) {
            //need to mint more
            uint256 vaultWrapperSharesToMint = desiredVaultWrapperBalance - currentVaultWrapperBalance;
            uint256 assetsNeeded = underlyingVault.previewMint(vaultWrapper.previewMint(vaultWrapperSharesToMint));

            poolManager.take(Currency.wrap(address(asset)), address(this), assetsNeeded);
            poolManager.burn(address(this), Currency.wrap(address(asset)).toId(), assetsNeeded);

            poolManager.sync(Currency.wrap(address(vaultWrapper)));
            //here, we use previewMint to give us a very close estimate of shares to mint but we do not rely on it being exact
            //we simply deposit the assetsNeeded and accept however many shares we get (this will be very close to vaultWrapperSharesToMint)
            uint256 vaultWrapperSharesMinted = _deposit(
                vaultWrapper, address(underlyingVault), asset, address(this), assetsNeeded, address(poolManager)
            );
            poolManager.mint(address(this), Currency.wrap(address(vaultWrapper)).toId(), vaultWrapperSharesMinted);
            poolManager.settle();
        } else {
            uint256 vaultWrapperSharesToRedeem = currentVaultWrapperBalance - desiredVaultWrapperBalance;

            poolManager.take(Currency.wrap(address(vaultWrapper)), address(this), vaultWrapperSharesToRedeem);
            poolManager.burn(address(this), Currency.wrap(address(vaultWrapper)).toId(), vaultWrapperSharesToRedeem);

            poolManager.sync(Currency.wrap(address(asset)));
            uint256 assetsReceived = _redeem(
                vaultWrapper, address(underlyingVault), address(this), vaultWrapperSharesToRedeem, address(poolManager)
            );
            poolManager.mint(address(this), Currency.wrap(address(asset)).toId(), assetsReceived);
            poolManager.settle();
        }
    }

    function addWarmLiquidity(IERC4626 vaultWrapper, uint256 assetAmount) external {
        if (assetAmount == 0) revert ZeroAmountNotAllowed();
        poolManager.unlock(abi.encode(_msgSender(), true, vaultWrapper, assetAmount));
    }

    function removeWarmLiquidity(IERC4626 vaultWrapper, uint256 assetAmount) external {
        poolManager.unlock(abi.encode(_msgSender(), false, vaultWrapper, assetAmount));
    }

    function reBalance(IERC4626 vaultWrapper) external {
        poolManager.unlock(abi.encode(_msgSender(), true, vaultWrapper, 0));
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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
