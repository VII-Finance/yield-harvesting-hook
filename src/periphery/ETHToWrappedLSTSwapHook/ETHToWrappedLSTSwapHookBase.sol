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
/// Concrete subclasses implement four token-conversion primitives:
///   _rebaseToWrapped, _wrappedToRebase, _getWrappedByRebase, _getRebaseByWrapped
abstract contract ETHToWrappedLSTSwapHookBase is BaseHook, IHookEvents, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    Currency public constant ETH_CURRENCY = Currency.wrap(address(0));
    uint256 public constant Q96_INVERSE_CONSTANT = 2 ** 192;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IHooks public immutable yieldHarvestingHook;
    IERC4626 public immutable wethVault;
    IERC4626 public immutable lstVault;
    IERC4626 public immutable wethVaultWrapper;
    IERC4626 public immutable lstVaultWrapper;
    address public immutable REBASING_LST;
    address public immutable WRAPPED_LST;
    bool public immutable isWethVaultWrapperCurrency0;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    PoolKey private vaultWrapperPoolKey;

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

    function _rebaseToWrapped(uint256 rebaseAmount) internal virtual returns (uint256);
    function _wrappedToRebase(uint256 wrappedAmount) internal virtual returns (uint256);
    function _getWrappedByRebase(uint256 rebaseAmount) internal view virtual returns (uint256);
    function _getRebaseByWrapped(uint256 wrappedAmount) internal view virtual returns (uint256);

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
        int24 _tickSpacing
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

        IERC20(WETH).forceApprove(address(_wethVault), type(uint256).max);
        IERC20(WETH).forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(WETH, address(_wethVault), type(uint160).max, type(uint48).max);
        IERC20(address(_wethVault)).forceApprove(address(_wethVaultWrapper), type(uint256).max);
        IERC20(_rebasingLST).forceApprove(address(_lstVault), type(uint256).max);
        IERC20(address(_lstVault)).forceApprove(address(_lstVaultWrapper), type(uint256).max);
        IERC20(_rebasingLST).forceApprove(_wrappedLST, type(uint256).max);

        _poolManager.initialize(
            PoolKey({
                currency0: ETH_CURRENCY,
                currency1: Currency.wrap(_wrappedLST),
                fee: _fee,
                tickSpacing: _tickSpacing,
                hooks: IHooks(address(this))
            }),
            SQRT_PRICE_1_1
        );
    }

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

        _emitHookSwap(key, sender, params.zeroForOne, isExactInput, amountIn, amountOut);

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
        uint256 vaultSharesIn = _depositToVaultWrapper(isETHtoLST, amountIn);
        uint256 vaultSharesOut = _swapInVaultPool(vaultPoolZeroForOne, sqrtPriceLimit, vaultSharesIn, true);
        amountOut = _redeemFromVaultWrapper(!isETHtoLST, vaultSharesOut);
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
            uint256 lstVaultSharesNeeded = lstVault.previewWithdraw(_getRebaseByWrapped(amountOut));
            vaultSharesNeeded = lstVaultWrapper.previewWithdraw(lstVaultSharesNeeded);
        } else {
            vaultSharesNeeded = wethVaultWrapper.previewWithdraw(wethVault.previewWithdraw(amountOut));
        }

        uint256 vaultSharesIn = _swapInVaultPool(vaultPoolZeroForOne, sqrtPriceLimit, vaultSharesNeeded, false);
        amountOut = _redeemFromVaultWrapper(!isETHtoLST, vaultSharesNeeded);
        amountIn = _mintToVaultWrapper(isETHtoLST, vaultSharesIn);
    }

    function _emitHookSwap(
        PoolKey calldata key,
        address sender,
        bool zeroForOne,
        bool isExactInput,
        uint256 amountIn,
        uint256 amountOut
    ) private {
        int128 sign = isExactInput ? int128(1) : int128(-1);
        int128 inSigned = sign * amountIn.toInt256().toInt128();
        int128 outSigned = -(sign * amountOut.toInt256().toInt128());
        emit HookSwap(
            PoolId.unwrap(key.toId()),
            sender,
            zeroForOne ? inSigned : outSigned,
            zeroForOne ? outSigned : inSigned,
            0,
            0
        );
    }

    // ── Unified deposit: asset → vault wrapper (covers both ETH and LST sides) ─

    function _depositToVaultWrapper(bool isETH, uint256 amount) private returns (uint256 vaultWrapperShares) {
        Currency vaultWrapperCurrency =
            isETH ? Currency.wrap(address(wethVaultWrapper)) : Currency.wrap(address(lstVaultWrapper));
        Currency nativeCurrency = isETH ? ETH_CURRENCY : Currency.wrap(WRAPPED_LST);
        uint256 warmAmount = isETH ? amount : _getRebaseByWrapped(amount);
        poolManager.sync(vaultWrapperCurrency);
        if (warmAmount <= poolManager.balanceOf(address(this), vaultWrapperCurrency.toId())) {
            poolManager.burn(address(this), vaultWrapperCurrency.toId(), warmAmount);
            poolManager.mint(address(this), nativeCurrency.toId(), amount);
            poolManager.settle();
            return warmAmount;
        }
        poolManager.take(nativeCurrency, address(this), amount);
        vaultWrapperShares = isETH ? _depositETHVaultChain(amount) : _depositLSTVaultChain(_wrappedToRebase(amount));
        poolManager.settle();
    }

    // ── Unified redeem: vault wrapper → asset ────────────────────────────────

    function _redeemFromVaultWrapper(bool isETH, uint256 shares) private returns (uint256 amount) {
        Currency nativeCurrency = isETH ? ETH_CURRENCY : Currency.wrap(WRAPPED_LST);
        Currency vaultWrapperCurrency =
            isETH ? Currency.wrap(address(wethVaultWrapper)) : Currency.wrap(address(lstVaultWrapper));
        uint256 warmAmount = isETH ? shares : _getWrappedByRebase(shares);
        poolManager.sync(nativeCurrency);
        if (warmAmount <= poolManager.balanceOf(address(this), nativeCurrency.toId())) {
            poolManager.burn(address(this), nativeCurrency.toId(), warmAmount);
            poolManager.mint(address(this), vaultWrapperCurrency.toId(), shares);
            poolManager.settle();
            return warmAmount;
        }
        poolManager.take(vaultWrapperCurrency, address(this), shares);
        if (isETH) {
            amount = _redeemETHVaultChain(shares);
            poolManager.settle{value: amount}();
        } else {
            amount = _rebaseToWrapped(_redeemLSTVaultChain(shares));
            IERC20(WRAPPED_LST).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    // ── Unified mint: exact-output vault wrapper → asset ─────────────────────

    function _mintToVaultWrapper(bool isETH, uint256 vaultWrapperShares) private returns (uint256 amount) {
        Currency vaultWrapperCurrency =
            isETH ? Currency.wrap(address(wethVaultWrapper)) : Currency.wrap(address(lstVaultWrapper));
        Currency nativeCurrency = isETH ? ETH_CURRENCY : Currency.wrap(WRAPPED_LST);
        poolManager.sync(vaultWrapperCurrency);
        if (vaultWrapperShares <= poolManager.balanceOf(address(this), vaultWrapperCurrency.toId())) {
            amount = isETH ? vaultWrapperShares : _getWrappedByRebase(lstVaultWrapper.previewMint(vaultWrapperShares));
            poolManager.burn(address(this), vaultWrapperCurrency.toId(), vaultWrapperShares);
            poolManager.mint(address(this), nativeCurrency.toId(), amount);
        } else if (isETH) {
            uint256 wethVaultSharesNeeded = wethVaultWrapper.previewMint(vaultWrapperShares);
            amount = wethVault.previewMint(wethVaultSharesNeeded);
            poolManager.take(ETH_CURRENCY, address(this), amount);
            IWETH9(WETH).deposit{value: amount}();
            amount = wethVault.mint(wethVaultSharesNeeded, address(this));
            wethVaultWrapper.mint(vaultWrapperShares, address(poolManager));
        } else {
            uint256 lstVaultSharesNeeded = lstVaultWrapper.previewMint(vaultWrapperShares);
            uint256 rebaseNeeded = lstVault.previewMint(lstVaultSharesNeeded);
            amount = _getWrappedByRebase(rebaseNeeded) + 1;
            poolManager.take(Currency.wrap(WRAPPED_LST), address(this), amount);
            _wrappedToRebase(amount);
            lstVault.mint(lstVaultSharesNeeded, address(this));
            lstVaultWrapper.mint(vaultWrapperShares, address(poolManager));
        }
        poolManager.settle();
    }

    function _swapInVaultPool(bool zeroForOne, uint160 sqrtPriceLimitX96, uint256 amount, bool isExactInput)
        private
        returns (uint256 outputAmount)
    {
        BalanceDelta delta = poolManager.swap(
            vaultWrapperPoolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: isExactInput ? -amount.toInt256() : amount.toInt256(),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
        if (isExactInput) {
            outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        } else {
            outputAmount = zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        }
    }

    // ── External warm liquidity entry points ─────────────────────────────────

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

    function addWarmLiquidityLST(uint256 lstAmount) external {
        if (lstAmount == 0) revert ZeroAmount();
        IERC20(WRAPPED_LST).safeTransferFrom(msg.sender, address(this), lstAmount);
        poolManager.unlock(abi.encode(msg.sender, true, true, lstAmount));
    }

    function removeWarmLiquidityLST(uint256 lstAmount) external {
        poolManager.unlock(abi.encode(msg.sender, false, true, lstAmount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address user, bool isAdd, bool isLSTSide, uint256 amount) = abi.decode(data, (address, bool, bool, uint256));
        if (isAdd) {
            _addWarmLiquidity(!isLSTSide, user, amount);
        } else if (amount == 0) {
            _rebalanceSide(true);
            _rebalanceSide(false);
        } else {
            _removeWarmLiquidity(!isLSTSide, user, amount);
        }
        return "";
    }

    // ── Unified warm liquidity internals ─────────────────────────────────────

    function _addWarmLiquidity(bool isETH, address user, uint256 amount) private {
        uint256 half = amount / 2;
        uint256 remaining = amount - half;
        if (isETH) {
            poolManager.sync(Currency.wrap(address(wethVaultWrapper)));
            _depositETHVaultChain(half);
            poolManager.mint(address(this), Currency.wrap(address(wethVaultWrapper)).toId(), half);
            poolManager.settle();
            poolManager.sync(ETH_CURRENCY);
            poolManager.mint(address(this), ETH_CURRENCY.toId(), remaining);
            poolManager.settle{value: remaining}();
            warmLiquidityETH[user] += amount;
            totalWarmLiquidityETH += amount;
            emit WarmLiquidityETHAdded(user, amount);
        } else {
            uint256 rebaseFromHalf = _wrappedToRebase(half);
            poolManager.sync(Currency.wrap(address(lstVaultWrapper)));
            _depositLSTVaultChain(rebaseFromHalf);
            poolManager.mint(address(this), Currency.wrap(address(lstVaultWrapper)).toId(), rebaseFromHalf);
            poolManager.settle();
            poolManager.sync(Currency.wrap(WRAPPED_LST));
            IERC20(WRAPPED_LST).safeTransfer(address(poolManager), remaining);
            poolManager.mint(address(this), Currency.wrap(WRAPPED_LST).toId(), remaining);
            poolManager.settle();
            warmLiquidityLST[user] += amount;
            totalWarmLiquidityLST += amount;
            emit WarmLiquidityLSTAdded(user, amount);
        }
    }

    function _removeWarmLiquidity(bool isETH, address user, uint256 amount) private {
        if (isETH) {
            if (warmLiquidityETH[user] < amount) revert InsufficientWarmLiquidity();
            warmLiquidityETH[user] -= amount;
            totalWarmLiquidityETH -= amount;
            uint256 half = amount / 2;
            _takeAndBurnClaims(Currency.wrap(address(wethVaultWrapper)), address(this), half);
            uint256 ethReceived = _redeemETHVaultChain(half);
            _takeAndBurnClaims(ETH_CURRENCY, user, amount - half);
            (bool ok,) = payable(user).call{value: ethReceived}("");
            require(ok, "ETH transfer failed");
            emit WarmLiquidityETHRemoved(user, amount);
        } else {
            if (warmLiquidityLST[user] < amount) revert InsufficientWarmLiquidity();
            warmLiquidityLST[user] -= amount;
            totalWarmLiquidityLST -= amount;
            uint256 half = amount / 2;
            uint256 rebaseHalf = _getRebaseByWrapped(half);
            _takeAndBurnClaims(Currency.wrap(address(lstVaultWrapper)), address(this), rebaseHalf);
            IERC20(WRAPPED_LST).safeTransfer(user, _rebaseToWrapped(_redeemLSTVaultChain(rebaseHalf)));
            _takeAndBurnClaims(Currency.wrap(WRAPPED_LST), user, amount - half);
            emit WarmLiquidityLSTRemoved(user, amount);
        }
    }

    function _rebalanceSide(bool isETH) private {
        Currency vaultWrapperCurrency =
            isETH ? Currency.wrap(address(wethVaultWrapper)) : Currency.wrap(address(lstVaultWrapper));
        Currency nativeCurrency = isETH ? ETH_CURRENCY : Currency.wrap(WRAPPED_LST);
        uint256 desired = isETH ? totalWarmLiquidityETH / 2 : _getRebaseByWrapped(totalWarmLiquidityLST) / 2;
        uint256 current = poolManager.balanceOf(address(this), vaultWrapperCurrency.toId());
        if (current < desired) {
            uint256 delta = desired - current;
            if (isETH) {
                uint256 ethNeeded = wethVault.previewMint(wethVaultWrapper.previewMint(delta));
                _takeAndBurnClaims(ETH_CURRENCY, address(this), ethNeeded);
                poolManager.sync(vaultWrapperCurrency);
                poolManager.mint(address(this), vaultWrapperCurrency.toId(), _depositETHVaultChain(ethNeeded));
            } else {
                uint256 wrappedNeeded = _getWrappedByRebase(delta);
                _takeAndBurnClaims(nativeCurrency, address(this), wrappedNeeded);
                poolManager.sync(vaultWrapperCurrency);
                poolManager.mint(
                    address(this), vaultWrapperCurrency.toId(), _depositLSTVaultChain(_wrappedToRebase(wrappedNeeded))
                );
            }
            poolManager.settle();
        } else if (current > desired) {
            uint256 delta = current - desired;
            _takeAndBurnClaims(vaultWrapperCurrency, address(this), delta);
            poolManager.sync(nativeCurrency);
            if (isETH) {
                uint256 ethReceived = _redeemETHVaultChain(delta);
                poolManager.mint(address(this), nativeCurrency.toId(), ethReceived);
                poolManager.settle{value: ethReceived}();
            } else {
                uint256 wrappedReceived = _rebaseToWrapped(_redeemLSTVaultChain(delta));
                IERC20(WRAPPED_LST).safeTransfer(address(poolManager), wrappedReceived);
                poolManager.mint(address(this), nativeCurrency.toId(), wrappedReceived);
                poolManager.settle();
            }
        }
    }

    // ── Layer 1: recurring vault chain helpers ────────────────────────────────
    // Each chain appears 3× in the codebase; extracting to a function means
    // the bytecode is compiled once rather than inlined at every call site.

    function _depositETHVaultChain(uint256 ethAmount) private returns (uint256 sharesMinted) {
        IWETH9(WETH).deposit{value: ethAmount}();
        uint256 wethVaultShares = wethVault.deposit(ethAmount, address(this));
        sharesMinted = wethVaultWrapper.deposit(wethVaultShares, address(poolManager));
    }

    function _redeemETHVaultChain(uint256 shares) private returns (uint256 ethReceived) {
        uint256 wethVaultShares = wethVaultWrapper.redeem(shares, address(this), address(this));
        ethReceived = wethVault.redeem(wethVaultShares, address(this), address(this));
        IWETH9(WETH).withdraw(ethReceived);
    }

    function _depositLSTVaultChain(uint256 rebaseAmount) private returns (uint256 sharesMinted) {
        uint256 lstVaultShares = lstVault.deposit(rebaseAmount, address(this));
        sharesMinted = lstVaultWrapper.deposit(lstVaultShares, address(poolManager));
    }

    function _redeemLSTVaultChain(uint256 shares) private returns (uint256 rebaseAmount) {
        uint256 lstVaultShares = lstVaultWrapper.redeem(shares, address(this), address(this));
        rebaseAmount = lstVault.redeem(lstVaultShares, address(this), address(this));
    }

    /// @dev take(currency → recipient) + burn(hook's claim). Appears 7× across warm liquidity functions.
    function _takeAndBurnClaims(Currency currency, address recipient, uint256 amount) private {
        poolManager.take(currency, recipient, amount);
        poolManager.burn(address(this), currency.toId(), amount);
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

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
