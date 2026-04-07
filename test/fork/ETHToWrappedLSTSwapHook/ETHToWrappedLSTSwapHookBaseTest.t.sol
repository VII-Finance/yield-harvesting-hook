// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/BaseVaultsTest.t.sol";
import {ETHToWrappedLSTSwapHookBase} from "src/periphery/ETHToWrappedLSTSwapHook/ETHToWrappedLSTSwapHookBase.sol";
import {SmoothYieldVault} from "src/SmoothYieldVault.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

/// @notice Abstract base for fork tests of ETHToWrappedLSTSwapHook variants.
///
/// Concrete subclasses supply:
///   _rebasingLSTAddress()   — mainnet address of the rebasing token (stETH / eETH)
///   _wrappedLSTAddress()    — mainnet address of the wrapped token (wstETH / weETH)
///   _lstSmoothVaultToken()  — same as _rebasingLSTAddress(), used to create the vault
///   _deployConcreteHook()   — mine salt + deploy + set `hook`
///   _dealWrappedLST()       — obtain wrappedLST for a test address
///   _dealDustToHook()       — optional: deal rounding dust tokens to hook after deploy
///   deal()                  — override for rebasing tokens (Lido submit / ether.fi deposit)
abstract contract ETHToWrappedLSTSwapHookBaseTest is BaseVaultsTest {
    using PoolIdLibrary for PoolKey;

    // ── Shared mainnet addresses ─────────────────────────────────────────────
    address internal constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant EULER_WETH_VAULT = 0xc97AF70AB043927A5d9b682e77d1AF3c52559A4e;

    // ── Shared state ─────────────────────────────────────────────────────────
    ETHToWrappedLSTSwapHookBase public hook;
    SmoothYieldVault public lstSmoothVault;
    PoolKey public assetPoolKey;

    uint128 constant VAULT_POOL_LIQUIDITY = 10 ** 18;

    function _getForkBlock() internal pure override returns (uint256) {
        return 24796778;
    }

    // ── Abstract / virtual interface ─────────────────────────────────────────

    /// @dev Address of the rebasing LST (e.g. stETH, eETH).
    function _rebasingLSTAddress() internal pure virtual returns (address);

    /// @dev Address of the wrapped non-rebasing LST (e.g. wstETH, weETH).
    function _wrappedLSTAddress() internal pure virtual returns (address);

    /// @dev Mine salt and deploy the concrete hook; must set `hook` and `assetPoolKey`.
    function _deployConcreteHook(IERC4626 wethVW, IERC4626 lstVW) internal virtual;

    /// @dev Obtain at least `amount` of wrappedLST and deliver it to `to`.
    function _dealWrappedLST(address to, uint256 amount) internal virtual;

    /// @dev Optional: deal rounding-absorbing dust to the hook after deployment.
    function _dealDustToHook() internal virtual {}

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public virtual override {
        super.setUp();

        lstSmoothVault = new SmoothYieldVault(IERC20(_rebasingLSTAddress()), 1 days, address(this));

        (vaultWrapper0, vaultWrapper1) = vaultWrappersFactory.createERC4626VaultPool(
            IERC4626(address(lstSmoothVault)), IERC4626(EULER_WETH_VAULT), 3000, 60, Constants.SQRT_PRICE_1_1
        );

        if (address(vaultWrapper0) > address(vaultWrapper1)) {
            (vaultWrapper0, vaultWrapper1) = (vaultWrapper1, vaultWrapper0);
        }

        underlyingVault0 = MockERC4626(address(IERC4626(address(vaultWrapper0)).asset()));
        underlyingVault1 = MockERC4626(address(IERC4626(address(vaultWrapper1)).asset()));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(vaultWrapper0)),
            currency1: Currency.wrap(address(vaultWrapper1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: yieldHarvestingHook
        });

        _addLiquidityToVaultPool();
        _deployHook();
        _dealDustToHook();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Shared swap tests
    // ─────────────────────────────────────────────────────────────────────────

    function test_exactInput_ETHtoLST(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.05 ether);
        _swapExactIn(amountIn, true);
    }

    function test_exactInput_LSTtoETH(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.05 ether);
        _swapExactIn(amountIn, false);
    }

    function test_exactOutput_ETHtoLST(uint256 amountOut) public {
        amountOut = bound(amountOut, 0.001 ether, 0.03 ether);
        _swapExactOut(amountOut, true);
    }

    function test_exactOutput_LSTtoETH(uint256 amountOut) public {
        amountOut = bound(amountOut, 0.001 ether, 0.03 ether);
        _swapExactOut(amountOut, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Shared warm-liquidity tests
    // ─────────────────────────────────────────────────────────────────────────

    function test_addRemoveWarmLiquidityETH() public {
        uint256 ethAmount = 0.2 ether;
        vm.deal(address(this), ethAmount);

        hook.addWarmLiquidityETH{value: ethAmount}();
        assertEq(hook.warmLiquidityETH(address(this)), ethAmount);
        assertEq(hook.totalWarmLiquidityETH(), ethAmount);

        uint256 ethBefore = address(this).balance;
        hook.removeWarmLiquidityETH(ethAmount);
        assertGt(address(this).balance, ethBefore, "should receive ETH back");
        assertEq(hook.warmLiquidityETH(address(this)), 0);
    }

    function test_addRemoveWarmLiquidityLST() public {
        uint256 lstAmount = 0.1 ether;
        _dealWrappedLST(address(this), lstAmount);
        IERC20(_wrappedLSTAddress()).approve(address(hook), lstAmount);

        hook.addWarmLiquidityLST(lstAmount);
        assertEq(hook.warmLiquidityLST(address(this)), lstAmount);

        uint256 lstBefore = IERC20(_wrappedLSTAddress()).balanceOf(address(this));
        hook.removeWarmLiquidityLST(lstAmount);
        assertGt(IERC20(_wrappedLSTAddress()).balanceOf(address(this)), lstBefore, "should receive LST back");
        assertEq(hook.warmLiquidityLST(address(this)), 0);
    }

    function test_warmPath_ETHtoLST(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.05 ether);
        vm.deal(address(this), 1 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();
        _dealWrappedLST(address(this), 0.5 ether);
        IERC20(_wrappedLSTAddress()).approve(address(hook), 0.5 ether);
        hook.addWarmLiquidityLST(0.5 ether);

        _swapExactIn(amountIn, true);
    }

    function test_warmPath_LSTtoETH(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.05 ether);
        vm.deal(address(this), 1 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();
        _dealWrappedLST(address(this), 0.5 ether);
        IERC20(_wrappedLSTAddress()).approve(address(hook), 0.5 ether);
        hook.addWarmLiquidityLST(0.5 ether);

        _swapExactIn(amountIn, false);
    }

    function test_addLiquidityDirectlyBlocked() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            assetPoolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(assetPoolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(assetPoolKey.tickSpacing),
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
    }

    function test_rebalance_afterETHHeavySwaps() public {
        // Seed warm liquidity on both sides
        vm.deal(address(this), 1 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();
        _dealWrappedLST(address(this), 0.5 ether);
        IERC20(_wrappedLSTAddress()).approve(address(hook), 0.5 ether);
        hook.addWarmLiquidityLST(0.5 ether);

        // Drain ETH warm side by doing many ETH→LST swaps
        for (uint256 i = 0; i < 5; i++) {
            _swapExactIn(0.05 ether, true);
        }

        uint256 vaultWrapperBalBefore =
            poolManager.balanceOf(address(hook), Currency.wrap(address(hook.wethVaultWrapper())).toId());
        uint256 desired = hook.totalWarmLiquidityETH() / 2;

        hook.rebalanceWarmLiquidity();

        uint256 vaultWrapperBalAfter =
            poolManager.balanceOf(address(hook), Currency.wrap(address(hook.wethVaultWrapper())).toId());

        // After rebalance, vault wrapper balance should be closer to desired
        uint256 diffBefore =
            vaultWrapperBalBefore > desired ? vaultWrapperBalBefore - desired : desired - vaultWrapperBalBefore;
        uint256 diffAfter =
            vaultWrapperBalAfter > desired ? vaultWrapperBalAfter - desired : desired - vaultWrapperBalAfter;

        assertLt(diffAfter, diffBefore, "rebalance should move closer to 50/50");
    }

    function test_rebalance_afterLSTHeavySwaps() public {
        vm.deal(address(this), 1 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();
        _dealWrappedLST(address(this), 0.5 ether);
        IERC20(_wrappedLSTAddress()).approve(address(hook), 0.5 ether);
        hook.addWarmLiquidityLST(0.5 ether);

        for (uint256 i = 0; i < 5; i++) {
            _swapExactIn(0.05 ether, false);
        }

        uint256 lstVWId = Currency.wrap(address(hook.lstVaultWrapper())).toId();
        uint256 balBefore = poolManager.balanceOf(address(hook), lstVWId);
        uint256 desired = hook.lstVWDesiredBalance();

        hook.rebalanceWarmLiquidity();

        uint256 balAfter = poolManager.balanceOf(address(hook), lstVWId);

        uint256 diffBefore = balBefore > desired ? balBefore - desired : desired - balBefore;
        uint256 diffAfter = balAfter > desired ? balAfter - desired : desired - balAfter;

        assertLt(diffAfter, diffBefore, "LST side rebalance should move closer to 50/50");
    }

    function test_rebalance_noopWhenBalanced() public {
        vm.deal(address(this), 1 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();

        uint256 balBefore = poolManager.balanceOf(address(hook), Currency.wrap(address(hook.wethVaultWrapper())).toId());

        hook.rebalanceWarmLiquidity();

        uint256 balAfter = poolManager.balanceOf(address(hook), Currency.wrap(address(hook.wethVaultWrapper())).toId());

        // Tolerance of 1 wei for rounding
        assertApproxEqAbs(balAfter, balBefore, 1, "already balanced should not move");
    }

    function test_rebalance_calledByAnyone() public {
        vm.deal(address(this), 0.5 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();
        _swapExactIn(0.05 ether, true);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        hook.rebalanceWarmLiquidity(); // must not revert
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _addLiquidityToVaultPool() internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
            liquidityDelta: int256(uint256(VAULT_POOL_LIQUIDITY)),
            salt: 0
        });
        modifyLiquidity(params, Constants.SQRT_PRICE_1_1);
    }

    function _deployHook() internal {
        IERC4626 wethVW;
        IERC4626 lstVW;
        address vw0Asset = IERC4626(address(vaultWrapper0)).asset();
        if (IERC4626(vw0Asset).asset() == WETH_ADDR) {
            wethVW = IERC4626(address(vaultWrapper0));
            lstVW = IERC4626(address(vaultWrapper1));
        } else {
            wethVW = IERC4626(address(vaultWrapper1));
            lstVW = IERC4626(address(vaultWrapper0));
        }
        _deployConcreteHook(wethVW, lstVW);
    }

    function _swapExactIn(uint256 amountIn, bool zeroForOne) internal {
        address wrappedLST = _wrappedLSTAddress();
        if (zeroForOne) {
            vm.deal(address(this), amountIn);
            vm.deal(address(poolManager), address(poolManager).balance + amountIn);
        } else {
            _dealWrappedLST(address(this), amountIn);
            IERC20(wrappedLST).approve(address(swapRouter), amountIn);
            _dealWrappedLST(address(poolManager), amountIn);
        }

        uint256 outBefore = zeroForOne ? IERC20(wrappedLST).balanceOf(address(this)) : address(this).balance;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = swapRouter.swap{value: zeroForOne ? amountIn : 0}(
            assetPoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 amountOut = zeroForOne ? uint256(int256(delta.amount1())) : uint256(-int256(delta.amount0()));

        assertGt(amountOut, 0, "no output");
        uint256 outAfter = zeroForOne ? IERC20(wrappedLST).balanceOf(address(this)) : address(this).balance;
        assertGt(outAfter, outBefore, "balance did not increase");
    }

    function _swapExactOut(uint256 amountOut, bool zeroForOne) internal {
        address wrappedLST = _wrappedLSTAddress();
        uint256 maxIn = amountOut * 2;

        if (zeroForOne) {
            vm.deal(address(this), maxIn);
            vm.deal(address(poolManager), address(poolManager).balance + maxIn);
        } else {
            _dealWrappedLST(address(this), maxIn);
            IERC20(wrappedLST).approve(address(swapRouter), maxIn);
            _dealWrappedLST(address(poolManager), maxIn);
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = swapRouter.swap{value: zeroForOne ? maxIn : 0}(
            assetPoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 amountIn = zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        assertGt(amountIn, 0, "no input consumed");
    }
}
