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
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IHookEvents} from "src/interfaces/IHookEvents.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @notice Abstract base for ETH ↔ wrapped-LST (e.g. wstETH, weETH) hooks routed through a
///         VII vault wrapper pool (WETH vault wrapper ↔ rebasing-LST vault wrapper).
///
/// All logic is shared here. Concrete subclasses supply four token-conversion primitives:
///   _rebaseToWrapped   — e.g. stETH  → wstETH  (IWstETH.wrap)
///   _wrappedToRebase   — e.g. wstETH → stETH   (IWstETH.unwrap)
///   _getWrappedByRebase — rate query: rebase amount → expected wrapped amount
///   _getRebaseByWrapped — rate query: wrapped amount → expected rebase amount
///
/// Slow path: ETH → WETH → wethVault → wethVaultWrapper → [vault pool] →
///            lstVaultWrapper → lstVault → rebasingLST → wrappedLST  (and reverse).
///
/// Warm path: LPs pre-deposit so the hook skips multi-step conversions using
///   1:1 approximations:
///   - ETH ↔ wethVaultWrapper shares at 1:1
///   - lstVaultWrapper shares ↔ wrappedLST at current on-chain rate
abstract contract ETHToWrappedLSTSwapHookBase is BaseHook, IHookEvents, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ── Shared mainnet addresses ─────────────────────────────────────────────
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Native ETH is address(0) — always currency0 since 0 < any ERC20 address.
    Currency public constant ETH_CURRENCY = Currency.wrap(address(0));

    uint256 public constant Q96_INVERSE_CONSTANT = 2 ** 192;

    // ── Immutables ───────────────────────────────────────────────────────────
    IHooks public immutable yieldHarvestingHook;

    IERC4626 public immutable wethVault; // e.g. Euler eWETH
    IERC4626 public immutable lstVault; // e.g. SmoothYieldVault(stETH / eETH)
    IERC4626 public immutable wethVaultWrapper; // VII vault wrapper for WETH side
    IERC4626 public immutable lstVaultWrapper; // VII vault wrapper for LST side

    /// @dev Rebasing LST underlying the wrapped token (e.g. stETH, eETH).
    address public immutable REBASING_LST;
    /// @dev Wrapped non-rebasing LST that forms currency1 (e.g. wstETH, weETH).
    address public immutable WRAPPED_LST;

    /// @dev True when address(wethVaultWrapper) < address(lstVaultWrapper),
    ///      i.e. wethVaultWrapper is currency0 in the vault pool.
    bool public immutable isWethVaultWrapperCurrency0;

    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    PoolKey private vaultWrapperPoolKey;

    // ── Warm liquidity ───────────────────────────────────────────────────────
    mapping(address user => uint256 ethDeposited) public warmLiquidityETH;
    mapping(address user => uint256 lstDeposited) public warmLiquidityLST;
    uint256 public totalWarmLiquidityETH;
    uint256 public totalWarmLiquidityLST;

    event WarmLiquidityETHAdded(address indexed user, uint256 ethAmount);
    event WarmLiquidityETHRemoved(address indexed user, uint256 ethAmount);
    event WarmLiquidityLSTAdded(address indexed user, uint256 lstAmount);
    event WarmLiquidityLSTRemoved(address indexed user, uint256 lstAmount);

    error InsufficientWarmLiquidity();
    error ZeroAmount();

    // ── LST conversion primitives (implemented by concrete subclasses) ────────

    /// @dev Convert rebasingLST → wrappedLST (e.g. stETH→wstETH via wrap).
    function _rebaseToWrapped(uint256 rebaseAmount) internal virtual returns (uint256);

    /// @dev Convert wrappedLST → rebasingLST (e.g. wstETH→stETH via unwrap).
    function _wrappedToRebase(uint256 wrappedAmount) internal virtual returns (uint256);

    /// @dev Rate query: how many wrappedLST correspond to `rebaseAmount` rebasingLST.
    function _getWrappedByRebase(uint256 rebaseAmount) internal view virtual returns (uint256);

    /// @dev Rate query: how many rebasingLST correspond to `wrappedAmount` wrappedLST.
    function _getRebaseByWrapped(uint256 wrappedAmount) internal view virtual returns (uint256);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        IPoolManager _poolManager,
        IERC4626 _wethVault,
        IERC4626 _lstVault,
        IERC4626 _wethVaultWrapper,
        IERC4626 _lstVaultWrapper,
        address _rebasingLST,
        address _wrappedLST,
        IHooks _yieldHarvestingHook,
        uint24 _fee,
        int24 _tickSpacing,
        uint160 _initialSqrtPriceX96
    ) BaseHook(_poolManager) {
        yieldHarvestingHook = _yieldHarvestingHook;
        wethVault = _wethVault;
        lstVault = _lstVault;
        wethVaultWrapper = _wethVaultWrapper;
        lstVaultWrapper = _lstVaultWrapper;
        REBASING_LST = _rebasingLST;
        WRAPPED_LST = _wrappedLST;
        fee = _fee;
        tickSpacing = _tickSpacing;
        isWethVaultWrapperCurrency0 = address(_wethVaultWrapper) < address(_lstVaultWrapper);

        vaultWrapperPoolKey = PoolKey({
            currency0: isWethVaultWrapperCurrency0
                ? Currency.wrap(address(_wethVaultWrapper))
                : Currency.wrap(address(_lstVaultWrapper)),
            currency1: isWethVaultWrapperCurrency0
                ? Currency.wrap(address(_lstVaultWrapper))
                : Currency.wrap(address(_wethVaultWrapper)),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: _yieldHarvestingHook
        });

        // ── Token approvals ────────────────────────────────────────────────
        IERC20(WETH).forceApprove(address(_wethVault), type(uint256).max);
        IERC20(WETH).forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(WETH, address(_wethVault), type(uint160).max, type(uint48).max);
        IERC20(address(_wethVault)).forceApprove(address(_wethVaultWrapper), type(uint256).max);
        IERC20(_rebasingLST).forceApprove(address(_lstVault), type(uint256).max);
        IERC20(address(_lstVault)).forceApprove(address(_lstVaultWrapper), type(uint256).max);
        // rebasingLST → wrappedLST (wrap pulls rebasingLST via transferFrom)
        IERC20(_rebasingLST).forceApprove(_wrappedLST, type(uint256).max);

        // ── Initialize the ETH/wrappedLST asset pool ──────────────────────
        // ETH (address 0) < any ERC20 address, so ETH is always currency0.
        PoolKey memory assetPoolKey = PoolKey({
            currency0: ETH_CURRENCY,
            currency1: Currency.wrap(_wrappedLST),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(this))
        });
        _poolManager.initialize(assetPoolKey, _initialSqrtPriceX96);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook permissions
    // ─────────────────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
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

    function _beforeInitialize(address caller, PoolKey calldata, uint160) internal view override returns (bytes4) {
        require(caller == address(this), "NotSelf");
        return this.beforeInitialize.selector;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core swap
    // ─────────────────────────────────────────────────────────────────────────

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;
        bool isETHtoLST = params.zeroForOne;

        bool vaultPoolZeroForOne = isWethVaultWrapperCurrency0 ? isETHtoLST : !isETHtoLST;
        uint160 sqrtPriceLimit =
            !isWethVaultWrapperCurrency0 ? _invertSqrtPriceX96(params.sqrtPriceLimitX96) : params.sqrtPriceLimitX96;

        uint256 amountIn;
        uint256 amountOut;

        if (isExactInput) {
            (amountIn, amountOut) =
                _handleExactInput(isETHtoLST, vaultPoolZeroForOne, sqrtPriceLimit, params.amountSpecified);
        } else {
            (amountIn, amountOut) =
                _handleExactOutput(isETHtoLST, vaultPoolZeroForOne, sqrtPriceLimit, params.amountSpecified);
        }

        if (isExactInput) {
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                params.zeroForOne ? amountIn.toInt256().toInt128() : -(amountOut.toInt256().toInt128()),
                params.zeroForOne ? -(amountOut.toInt256().toInt128()) : amountIn.toInt256().toInt128(),
                0,
                0
            );
        } else {
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                params.zeroForOne ? -(amountIn.toInt256().toInt128()) : amountOut.toInt256().toInt128(),
                params.zeroForOne ? amountOut.toInt256().toInt128() : -(amountIn.toInt256().toInt128()),
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
        bool isETHtoLST,
        bool vaultPoolZeroForOne,
        uint160 sqrtPriceLimit,
        int256 amountSpecified
    ) private returns (uint256 amountIn, uint256 amountOut) {
        amountIn = (-amountSpecified).toUint256();

        uint256 vaultSharesIn = isETHtoLST ? _depositETHToVaultWrapper(amountIn) : _depositLSTToVaultWrapper(amountIn);

        uint256 vaultSharesOut = _swapInVaultPool(vaultPoolZeroForOne, sqrtPriceLimit, vaultSharesIn, true);

        amountOut = isETHtoLST
            ? _redeemLSTVaultWrapperToWrappedLST(vaultSharesOut)
            : _redeemWethVaultWrapperToETH(vaultSharesOut);
    }

    function _handleExactOutput(
        bool isETHtoLST,
        bool vaultPoolZeroForOne,
        uint160 sqrtPriceLimit,
        int256 amountSpecified
    ) private returns (uint256 amountIn, uint256 amountOut) {
        amountOut = amountSpecified.toUint256();

        uint256 vaultSharesNeeded;
        if (isETHtoLST) {
            uint256 rebaseNeeded = _getRebaseByWrapped(amountOut);
            uint256 lstVaultSharesNeeded = lstVault.previewWithdraw(rebaseNeeded);
            vaultSharesNeeded = lstVaultWrapper.previewWithdraw(lstVaultSharesNeeded);
        } else {
            uint256 wethVaultSharesNeeded = wethVault.previewWithdraw(amountOut);
            vaultSharesNeeded = wethVaultWrapper.previewWithdraw(wethVaultSharesNeeded);
        }

        uint256 vaultSharesIn = _swapInVaultPool(vaultPoolZeroForOne, sqrtPriceLimit, vaultSharesNeeded, false);

        // Use the actual amount produced (may differ from amountOut due to vault rounding).
        if (isETHtoLST) {
            amountOut = _redeemLSTVaultWrapperToWrappedLST(vaultSharesNeeded);
        } else {
            amountOut = _redeemWethVaultWrapperToETH(vaultSharesNeeded);
        }

        amountIn = isETHtoLST ? _mintETHToVaultWrapper(vaultSharesIn) : _mintLSTToVaultWrapper(vaultSharesIn);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Input conversion: asset → vault wrapper
    // ─────────────────────────────────────────────────────────────────────────

    function _depositETHToVaultWrapper(uint256 ethAmount) private returns (uint256 vaultWrapperShares) {
        Currency wethVWCurrency = Currency.wrap(address(wethVaultWrapper));
        poolManager.sync(wethVWCurrency);

        if (ethAmount <= poolManager.balanceOf(address(this), wethVWCurrency.toId())) {
            poolManager.burn(address(this), wethVWCurrency.toId(), ethAmount);
            poolManager.mint(address(this), ETH_CURRENCY.toId(), ethAmount);
            vaultWrapperShares = ethAmount;
        } else {
            poolManager.take(ETH_CURRENCY, address(this), ethAmount);
            IWETH9(WETH).deposit{value: ethAmount}();
            uint256 wethVaultShares = wethVault.deposit(ethAmount, address(this));
            vaultWrapperShares = wethVaultWrapper.deposit(wethVaultShares, address(poolManager));
        }
        poolManager.settle();
    }

    /// @dev wrappedLST → lstVaultWrapper shares.
    ///      Warm rate: wrappedLST → rebaseEquivalent (via rate query) ≈ vault wrapper shares.
    function _depositLSTToVaultWrapper(uint256 wrappedLSTAmount) private returns (uint256 vaultWrapperShares) {
        Currency lstVWCurrency = Currency.wrap(address(lstVaultWrapper));
        poolManager.sync(lstVWCurrency);

        uint256 rebaseEquivalent = _getRebaseByWrapped(wrappedLSTAmount);
        if (rebaseEquivalent <= poolManager.balanceOf(address(this), lstVWCurrency.toId())) {
            poolManager.burn(address(this), lstVWCurrency.toId(), rebaseEquivalent);
            poolManager.mint(address(this), Currency.wrap(WRAPPED_LST).toId(), wrappedLSTAmount);
            vaultWrapperShares = rebaseEquivalent;
        } else {
            poolManager.take(Currency.wrap(WRAPPED_LST), address(this), wrappedLSTAmount);
            uint256 rebaseReceived = _wrappedToRebase(wrappedLSTAmount);
            uint256 lstVaultShares = lstVault.deposit(rebaseReceived, address(this));
            vaultWrapperShares = lstVaultWrapper.deposit(lstVaultShares, address(poolManager));
        }
        poolManager.settle();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Output conversion: vault wrapper → asset
    // ─────────────────────────────────────────────────────────────────────────

    function _redeemLSTVaultWrapperToWrappedLST(uint256 shares) private returns (uint256 wrappedAmount) {
        Currency wrappedLSTCurrency = Currency.wrap(WRAPPED_LST);
        poolManager.sync(wrappedLSTCurrency);

        wrappedAmount = _getWrappedByRebase(shares);
        if (wrappedAmount <= poolManager.balanceOf(address(this), wrappedLSTCurrency.toId())) {
            poolManager.burn(address(this), wrappedLSTCurrency.toId(), wrappedAmount);
            poolManager.mint(address(this), Currency.wrap(address(lstVaultWrapper)).toId(), shares);
        } else {
            poolManager.take(Currency.wrap(address(lstVaultWrapper)), address(this), shares);
            uint256 lstVaultShares = lstVaultWrapper.redeem(shares, address(this), address(this));
            uint256 rebaseAmount = lstVault.redeem(lstVaultShares, address(this), address(this));
            wrappedAmount = _rebaseToWrapped(rebaseAmount);
            IERC20(WRAPPED_LST).safeTransfer(address(poolManager), wrappedAmount);
        }
        poolManager.settle();
    }

    function _redeemWethVaultWrapperToETH(uint256 shares) private returns (uint256 ethAmount) {
        poolManager.sync(ETH_CURRENCY);
        ethAmount = shares;

        if (ethAmount <= poolManager.balanceOf(address(this), ETH_CURRENCY.toId())) {
            poolManager.burn(address(this), ETH_CURRENCY.toId(), ethAmount);
            poolManager.mint(address(this), Currency.wrap(address(wethVaultWrapper)).toId(), shares);
        } else {
            poolManager.take(Currency.wrap(address(wethVaultWrapper)), address(this), shares);
            uint256 wethVaultShares = wethVaultWrapper.redeem(shares, address(this), address(this));
            ethAmount = wethVault.redeem(wethVaultShares, address(this), address(this));
            IWETH9(WETH).withdraw(ethAmount);
            poolManager.settle{value: ethAmount}();
            return ethAmount;
        }
        poolManager.settle();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Exact-output mint helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _mintETHToVaultWrapper(uint256 vaultWrapperShares) private returns (uint256 ethAmount) {
        Currency wethVWCurrency = Currency.wrap(address(wethVaultWrapper));
        poolManager.sync(wethVWCurrency);

        if (vaultWrapperShares <= poolManager.balanceOf(address(this), wethVWCurrency.toId())) {
            poolManager.burn(address(this), wethVWCurrency.toId(), vaultWrapperShares);
            ethAmount = vaultWrapperShares;
            poolManager.mint(address(this), ETH_CURRENCY.toId(), ethAmount);
        } else {
            uint256 wethVaultSharesNeeded = wethVaultWrapper.previewMint(vaultWrapperShares);
            ethAmount = wethVault.previewMint(wethVaultSharesNeeded);
            poolManager.take(ETH_CURRENCY, address(this), ethAmount);
            IWETH9(WETH).deposit{value: ethAmount}();
            ethAmount = wethVault.mint(wethVaultSharesNeeded, address(this));
            wethVaultWrapper.mint(vaultWrapperShares, address(poolManager));
        }
        poolManager.settle();
    }

    /// @dev Mint exactly `vaultWrapperShares` of lstVaultWrapper from wrappedLST.
    ///      Returns the wrappedLST consumed.
    function _mintLSTToVaultWrapper(uint256 vaultWrapperShares) private returns (uint256 wrappedAmount) {
        Currency lstVWCurrency = Currency.wrap(address(lstVaultWrapper));
        poolManager.sync(lstVWCurrency);

        if (vaultWrapperShares <= poolManager.balanceOf(address(this), lstVWCurrency.toId())) {
            // Warm path: vault wrapper shares ≈ rebasingLST at 1:1, converted to wrappedLST.
            uint256 rebaseEquivalent = lstVaultWrapper.previewMint(vaultWrapperShares);
            wrappedAmount = _getWrappedByRebase(rebaseEquivalent);
            poolManager.burn(address(this), lstVWCurrency.toId(), vaultWrapperShares);
            poolManager.mint(address(this), Currency.wrap(WRAPPED_LST).toId(), wrappedAmount);
        } else {
            uint256 lstVaultSharesNeeded = lstVaultWrapper.previewMint(vaultWrapperShares);
            uint256 rebaseNeeded = lstVault.previewMint(lstVaultSharesNeeded);
            // +1 to absorb rounding in integer division during unwrap
            wrappedAmount = _getWrappedByRebase(rebaseNeeded) + 1;
            poolManager.take(Currency.wrap(WRAPPED_LST), address(this), wrappedAmount);
            _wrappedToRebase(wrappedAmount);
            lstVault.mint(lstVaultSharesNeeded, address(this));
            lstVaultWrapper.mint(vaultWrapperShares, address(poolManager));
        }
        poolManager.settle();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Vault pool swap
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // Warm liquidity — ETH side (external entry points)
    // ─────────────────────────────────────────────────────────────────────────

    function rebalanceWarmLiquidity() external {
        poolManager.unlock(abi.encode(address(0), false, false, uint256(0)));
    }

    function addWarmLiquidityETH() external payable {
        if (msg.value == 0) revert ZeroAmount();
        poolManager.unlock(abi.encode(msg.sender, true, false, msg.value));
    }

    function removeWarmLiquidityETH(uint256 ethAmount) external {
        poolManager.unlock(abi.encode(msg.sender, false, false, ethAmount));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Warm liquidity — LST side (entry points live in concrete subclasses)
    // ─────────────────────────────────────────────────────────────────────────

    function addWarmLiquidityLST(uint256 lstAmount) external {
        if (lstAmount == 0) revert ZeroAmount();
        IERC20(WRAPPED_LST).safeTransferFrom(msg.sender, address(this), lstAmount);
        poolManager.unlock(abi.encode(msg.sender, true, true, lstAmount));
    }

    function removeWarmLiquidityLST(uint256 lstAmount) external {
        poolManager.unlock(abi.encode(msg.sender, false, true, lstAmount));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Warm liquidity — unlock callback
    // ─────────────────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address user, bool isAdd, bool isLSTSide, uint256 amount) = abi.decode(data, (address, bool, bool, uint256));

        if (isAdd) {
            if (isLSTSide) _addWarmLiquidityLST(user, amount);
            else _addWarmLiquidityETH(user, amount);
        } else {
            if (amount == 0) {
                _rebalanceETH();
                _rebalanceLST();
            } else {
                if (isLSTSide) _removeWarmLiquidityLST(user, amount);
                else _removeWarmLiquidityETH(user, amount);
            }
        }
        return "";
    }

    function _addWarmLiquidityETH(address user, uint256 ethAmount) private {
        uint256 halfAmount = ethAmount / 2;

        poolManager.sync(Currency.wrap(address(wethVaultWrapper)));
        IWETH9(WETH).deposit{value: halfAmount}();
        uint256 wethVaultShares = wethVault.deposit(halfAmount, address(this));
        wethVaultWrapper.deposit(wethVaultShares, address(poolManager));
        poolManager.mint(address(this), Currency.wrap(address(wethVaultWrapper)).toId(), halfAmount);
        poolManager.settle();

        uint256 ethRemainder = ethAmount - halfAmount;
        poolManager.sync(ETH_CURRENCY);
        poolManager.mint(address(this), ETH_CURRENCY.toId(), ethRemainder);
        poolManager.settle{value: ethRemainder}();

        warmLiquidityETH[user] += ethAmount;
        totalWarmLiquidityETH += ethAmount;
        emit WarmLiquidityETHAdded(user, ethAmount);
    }

    function _addWarmLiquidityLST(address user, uint256 wrappedLSTAmount) private {
        uint256 half = wrappedLSTAmount / 2;

        // Convert half wrappedLST → rebasingLST → lstVaultWrapper claims in pool manager.
        uint256 rebaseFromHalf = _wrappedToRebase(half);
        poolManager.sync(Currency.wrap(address(lstVaultWrapper)));
        uint256 lstVaultShares = lstVault.deposit(rebaseFromHalf, address(this));
        lstVaultWrapper.deposit(lstVaultShares, address(poolManager));
        // Mint claims in rebase units (1:1 approximation).
        poolManager.mint(address(this), Currency.wrap(address(lstVaultWrapper)).toId(), rebaseFromHalf);
        poolManager.settle();

        // Keep other half as wrappedLST claims in pool manager.
        uint256 remaining = wrappedLSTAmount - half;
        poolManager.sync(Currency.wrap(WRAPPED_LST));
        IERC20(WRAPPED_LST).safeTransfer(address(poolManager), remaining);
        poolManager.mint(address(this), Currency.wrap(WRAPPED_LST).toId(), remaining);
        poolManager.settle();

        warmLiquidityLST[user] += wrappedLSTAmount;
        totalWarmLiquidityLST += wrappedLSTAmount;
        emit WarmLiquidityLSTAdded(user, wrappedLSTAmount);
    }

    function _rebalanceETH() private {
        uint256 desiredVaultWrapperBalance = totalWarmLiquidityETH / 2;
        uint256 currentVaultWrapperBalance =
            poolManager.balanceOf(address(this), Currency.wrap(address(wethVaultWrapper)).toId());

        if (currentVaultWrapperBalance < desiredVaultWrapperBalance) {
            uint256 sharesToMint = desiredVaultWrapperBalance - currentVaultWrapperBalance;
            uint256 ethNeeded = wethVault.previewMint(wethVaultWrapper.previewMint(sharesToMint));

            poolManager.take(ETH_CURRENCY, address(this), ethNeeded);
            poolManager.burn(address(this), ETH_CURRENCY.toId(), ethNeeded);

            poolManager.sync(Currency.wrap(address(wethVaultWrapper)));
            IWETH9(WETH).deposit{value: ethNeeded}();
            uint256 wethVaultShares = wethVault.deposit(ethNeeded, address(this));
            uint256 sharesMinted = wethVaultWrapper.deposit(wethVaultShares, address(poolManager));
            poolManager.mint(address(this), Currency.wrap(address(wethVaultWrapper)).toId(), sharesMinted);
            poolManager.settle();
        } else if (currentVaultWrapperBalance > desiredVaultWrapperBalance) {
            uint256 sharesToRedeem = currentVaultWrapperBalance - desiredVaultWrapperBalance;

            poolManager.take(Currency.wrap(address(wethVaultWrapper)), address(this), sharesToRedeem);
            poolManager.burn(address(this), Currency.wrap(address(wethVaultWrapper)).toId(), sharesToRedeem);

            poolManager.sync(ETH_CURRENCY);
            uint256 wethVaultShares = wethVaultWrapper.redeem(sharesToRedeem, address(this), address(this));
            uint256 ethReceived = wethVault.redeem(wethVaultShares, address(this), address(this));
            IWETH9(WETH).withdraw(ethReceived);
            poolManager.mint(address(this), ETH_CURRENCY.toId(), ethReceived);
            poolManager.settle{value: ethReceived}();
        }
    }

    function _rebalanceLST() private {
        uint256 desiredVaultWrapperBalance = _getRebaseByWrapped(totalWarmLiquidityLST) / 2;
        uint256 currentVaultWrapperBalance =
            poolManager.balanceOf(address(this), Currency.wrap(address(lstVaultWrapper)).toId());

        if (currentVaultWrapperBalance < desiredVaultWrapperBalance) {
            uint256 rebaseUnitsToMint = desiredVaultWrapperBalance - currentVaultWrapperBalance;
            uint256 wrappedNeeded = _getWrappedByRebase(rebaseUnitsToMint);

            poolManager.take(Currency.wrap(WRAPPED_LST), address(this), wrappedNeeded);
            poolManager.burn(address(this), Currency.wrap(WRAPPED_LST).toId(), wrappedNeeded);

            poolManager.sync(Currency.wrap(address(lstVaultWrapper)));
            uint256 rebaseReceived = _wrappedToRebase(wrappedNeeded);
            uint256 lstVaultShares = lstVault.deposit(rebaseReceived, address(this));
            uint256 sharesMinted = lstVaultWrapper.deposit(lstVaultShares, address(poolManager));
            poolManager.mint(address(this), Currency.wrap(address(lstVaultWrapper)).toId(), sharesMinted);
            poolManager.settle();
        } else if (currentVaultWrapperBalance > desiredVaultWrapperBalance) {
            uint256 sharesToRedeem = currentVaultWrapperBalance - desiredVaultWrapperBalance;

            poolManager.take(Currency.wrap(address(lstVaultWrapper)), address(this), sharesToRedeem);
            poolManager.burn(address(this), Currency.wrap(address(lstVaultWrapper)).toId(), sharesToRedeem);

            poolManager.sync(Currency.wrap(WRAPPED_LST));
            uint256 lstVaultShares = lstVaultWrapper.redeem(sharesToRedeem, address(this), address(this));
            uint256 rebaseAmount = lstVault.redeem(lstVaultShares, address(this), address(this));
            uint256 wrappedReceived = _rebaseToWrapped(rebaseAmount);
            IERC20(WRAPPED_LST).safeTransfer(address(poolManager), wrappedReceived);
            poolManager.mint(address(this), Currency.wrap(WRAPPED_LST).toId(), wrappedReceived);
            poolManager.settle();
        }
    }

    function _removeWarmLiquidityETH(address user, uint256 ethAmount) private {
        if (warmLiquidityETH[user] < ethAmount) revert InsufficientWarmLiquidity();

        warmLiquidityETH[user] -= ethAmount;
        totalWarmLiquidityETH -= ethAmount;

        uint256 halfAmount = ethAmount / 2;

        poolManager.take(Currency.wrap(address(wethVaultWrapper)), address(this), halfAmount);
        poolManager.burn(address(this), Currency.wrap(address(wethVaultWrapper)).toId(), halfAmount);
        uint256 wethVaultShares = wethVaultWrapper.redeem(halfAmount, address(this), address(this));
        uint256 wethReceived = wethVault.redeem(wethVaultShares, address(this), address(this));
        IWETH9(WETH).withdraw(wethReceived);

        uint256 ethRemainder = ethAmount - halfAmount;
        poolManager.take(ETH_CURRENCY, user, ethRemainder);
        poolManager.burn(address(this), ETH_CURRENCY.toId(), ethRemainder);

        // do the eth transfer at the end
        (bool ok,) = payable(user).call{value: wethReceived}("");
        require(ok, "ETH transfer failed");

        emit WarmLiquidityETHRemoved(user, ethAmount);
    }

    function _removeWarmLiquidityLST(address user, uint256 wrappedLSTAmount) private {
        if (warmLiquidityLST[user] < wrappedLSTAmount) revert InsufficientWarmLiquidity();

        warmLiquidityLST[user] -= wrappedLSTAmount;
        totalWarmLiquidityLST -= wrappedLSTAmount;

        uint256 half = wrappedLSTAmount / 2;
        uint256 rebaseHalf = _getRebaseByWrapped(half);

        // Redeem lstVaultWrapper claims → rebasingLST → wrap → send to user.
        poolManager.take(Currency.wrap(address(lstVaultWrapper)), address(this), rebaseHalf);
        poolManager.burn(address(this), Currency.wrap(address(lstVaultWrapper)).toId(), rebaseHalf);
        uint256 lstVaultShares = lstVaultWrapper.redeem(rebaseHalf, address(this), address(this));
        uint256 rebaseReceived = lstVault.redeem(lstVaultShares, address(this), address(this));
        uint256 wrappedFromRebase = _rebaseToWrapped(rebaseReceived);
        IERC20(WRAPPED_LST).safeTransfer(user, wrappedFromRebase);

        // Return wrappedLST claims to user.
        uint256 remaining = wrappedLSTAmount - half;
        poolManager.take(Currency.wrap(WRAPPED_LST), user, remaining);
        poolManager.burn(address(this), Currency.wrap(WRAPPED_LST).toId(), remaining);

        emit WarmLiquidityLSTRemoved(user, wrappedLSTAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utilities
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The desired lstVaultWrapper ERC-6909 balance (in rebase units) for a 50/50 split.
    function lstVWDesiredBalance() public view returns (uint256) {
        return _getRebaseByWrapped(totalWarmLiquidityLST) / 2;
    }

    function _invertSqrtPriceX96(uint160 x) internal pure returns (uint160 invX) {
        if (x == 0) return 0;
        invX = uint160(Q96_INVERSE_CONSTANT / x);
        if (invX <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (invX >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
    }

    receive() external payable {}
}
