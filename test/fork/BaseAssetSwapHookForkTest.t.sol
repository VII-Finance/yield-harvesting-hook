// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {
    PositionManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

abstract contract BaseAssetSwapHookForkTest is Test {
    using StateLibrary for PoolManager;

    PositionManager public positionManager;
    address public weth;
    address public evc;
    YieldHarvestingHook public yieldHarvestingHook;
    PoolManager public poolManager;
    PoolSwapTest public swapRouter;

    address initialOwner = makeAddr("initialOwner");

    PoolKey public assetsPoolKey;

    IERC20 public asset0;
    IERC20 public asset1;

    IERC4626 public vaultWrapper0;
    IERC4626 public vaultWrapper1;

    IERC4626 public underlyingVault0;
    IERC4626 public underlyingVault1;

    function setUp() public virtual {
        string memory fork_url = vm.envString("UNICHAIN_RPC_URL");
        vm.createSelectFork(fork_url, 29051161);

        evc = address(0x2A1176964F5D7caE5406B627Bf6166664FE83c60);
        weth = address(0x4200000000000000000000000000000000000006);
        poolManager = PoolManager(0x1F98400000000000000000000000000000000004);
        positionManager = PositionManager(payable(0x4529A01c7A0410167c5740C487A8DE60232617bf));
        yieldHarvestingHook = YieldHarvestingHook(0x777ef319C338C6ffE32A2283F603db603E8F2A80);

        asset0 = IERC20(0x078D782b760474a361dDA0AF3839290b0EF57AD6); // USDC
        asset1 = IERC20(0x9151434b16b9763660705744891fA906F660EcC5); // USDT

        vaultWrapper0 = IERC4626(0x9C383Fa23Dd981b361F0495Ba53dDeB91c750064); // VII-EUSDC
        vaultWrapper1 = IERC4626(0x7b793B1388e14F03e19dc562470e7D25B2Ae9b97); // VII-EUSDT

        underlyingVault0 = IERC4626(vaultWrapper0.asset());
        underlyingVault1 = IERC4626(vaultWrapper1.asset());

        swapRouter = new PoolSwapTest(poolManager);

        _deployHookAndInitPool();
    }

    /// @dev Subclasses deploy their hook and set `assetsPoolKey`, initializing the pool.
    function _deployHookAndInitPool() internal virtual;

    /// @dev Override to supply hookData for exact-input swaps (e.g. encoded vault wrappers).
    function _hookDataForExactIn() internal view virtual returns (bytes memory) {
        return "";
    }

    /// @dev Override to perform any setup required before an exact-output swap (e.g. setDefaultVaultWrappers).
    function _setupBeforeExactOut() internal virtual {}

    // ── Shared tests ─────────────────────────────────────────────────────────

    function test_assetsSwapExactAmountIn(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 10, 1e6);

        Currency currencyIn = zeroForOne ? assetsPoolKey.currency0 : assetsPoolKey.currency1;
        Currency currencyOut = zeroForOne ? assetsPoolKey.currency1 : assetsPoolKey.currency0;

        deal(Currency.unwrap(currencyIn), address(this), amountIn);
        _currencyToIERC20(currencyIn).approve(address(swapRouter), amountIn);
        deal(Currency.unwrap(currencyIn), address(poolManager), amountIn);

        uint256 assetBalanceBefore = currencyOut.balanceOf(address(this));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta swapDelta = swapRouter.swap(
            assetsPoolKey,
            swapParams,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookDataForExactIn()
        );

        uint256 assetOut = SafeCast.toUint256(zeroForOne ? swapDelta.amount1() : swapDelta.amount0());
        assertEq(assetOut, currencyOut.balanceOf(address(this)) - assetBalanceBefore, "Incorrect asset out amount");
    }

    function test_assetsSwapExactAmountOut(uint256 amountOut, bool zeroForOne) public {
        amountOut = bound(amountOut, 10, 1e6);

        Currency currencyIn = zeroForOne ? assetsPoolKey.currency0 : assetsPoolKey.currency1;

        deal(Currency.unwrap(currencyIn), address(this), 2 * amountOut);
        _currencyToIERC20(currencyIn).approve(address(swapRouter), 2 * amountOut);
        deal(Currency.unwrap(currencyIn), address(poolManager), 2 * amountOut);

        uint256 assetBalanceBefore = currencyIn.balanceOf(address(this));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        _setupBeforeExactOut();

        BalanceDelta swapDelta = swapRouter.swap(
            assetsPoolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 assetIn = SafeCast.toUint256(zeroForOne ? -swapDelta.amount0() : -swapDelta.amount1());
        assertEq(assetIn, assetBalanceBefore - currencyIn.balanceOf(address(this)), "Incorrect asset in amount");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _IERC20ToCurrency(IERC20 token) internal pure returns (Currency) {
        return Currency.wrap(address(token));
    }

    function _currencyToIERC20(Currency currency) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(currency));
    }

    function sortVaultWrappers(IERC4626 vaultWrapperA, IERC4626 vaultWrapperB, address _asset0, address _asset1)
        internal
        view
        returns (IERC4626, IERC4626)
    {
        IERC4626 underlyingVaultA = IERC4626(vaultWrapperA.asset());
        IERC4626 underlyingVaultB = IERC4626(vaultWrapperB.asset());

        if (underlyingVaultA.asset() == _asset0 && underlyingVaultB.asset() == _asset1) {
            return (vaultWrapperA, vaultWrapperB);
        } else if (underlyingVaultA.asset() == _asset1 && underlyingVaultB.asset() == _asset0) {
            return (vaultWrapperB, vaultWrapperA);
        } else {
            revert("Vault wrappers do not wrap the correct assets");
        }
    }
}
