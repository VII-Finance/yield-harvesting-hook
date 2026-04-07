// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ETHToWrappedLSTSwapHookBaseTest} from "test/fork/ETHToWrappedLSTSwapHook/ETHToWrappedLSTSwapHookBaseTest.t.sol";
import {ETHToWeETHSwapHook, IWeETH} from "src/periphery/ETHToWrappedLSTSwapHook/ETHToWeETHSwapHook.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

interface IDepositAdapter {
    function depositETHForWeETH(address _referral) external payable returns (uint256);
}

interface IWeETHUnwrap {
    function unwrap(uint256 amount) external returns (uint256);
}

/// @notice Fork test for ETHToWeETHSwapHook.
///
/// Vault pool: eETH SmoothYieldVault wrapper ↔ Euler WETH vault wrapper
/// Asset pool: ETH ↔ weETH (initialised inside the hook constructor)
contract ETHToWeETHSwapHookTest is ETHToWrappedLSTSwapHookBaseTest {
    address constant E_ETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant WE_ETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    IDepositAdapter constant DEPOSIT_ADAPTER = IDepositAdapter(0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2);

    ETHToWeETHSwapHook public weETHHook;

    // ── Abstract interface ───────────────────────────────────────────────────

    function _rebasingLSTAddress() internal pure override returns (address) {
        return E_ETH;
    }

    function _wrappedLSTAddress() internal pure override returns (address) {
        return WE_ETH;
    }

    function _deployConcreteHook(IERC4626 wethVW, IERC4626 lstVW) internal override {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            poolManager,
            IERC4626(EULER_WETH_VAULT),
            IERC4626(address(lstSmoothVault)),
            wethVW,
            lstVW,
            IHooks(address(yieldHarvestingHook)),
            uint24(3000),
            int24(60),
            Constants.SQRT_PRICE_1_1
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(ETHToWeETHSwapHook).creationCode, constructorArgs);

        weETHHook = new ETHToWeETHSwapHook{salt: salt}(
            poolManager,
            IERC4626(EULER_WETH_VAULT),
            IERC4626(address(lstSmoothVault)),
            wethVW,
            lstVW,
            IHooks(address(yieldHarvestingHook)),
            3000,
            60,
            Constants.SQRT_PRICE_1_1
        );

        hook = weETHHook;

        assetPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(WE_ETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(weETHHook))
        });
    }

    function _dealWrappedLST(address to, uint256 amount) internal override {
        _dealWeETH(to, amount);
    }

    function deal(address token, address to, uint256 give) internal override {
        if (token == E_ETH) {
            vm.deal(address(this), give + 10);
            DEPOSIT_ADAPTER.depositETHForWeETH{value: give + 10}(address(0));
            IWeETHUnwrap(WE_ETH).unwrap(IERC20(WE_ETH).balanceOf(address(this)));
            if (to != address(this)) IERC20(E_ETH).transfer(to, give);
        } else {
            super.deal(token, to, give);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // weETH-specific tests
    // ─────────────────────────────────────────────────────────────────────────

    function test_hookImmutables() public view {
        assertEq(address(hook.wethVault()), EULER_WETH_VAULT);
        assertEq(address(hook.lstVault()), address(lstSmoothVault));
        assertEq(hook.WRAPPED_LST(), WE_ETH);
        assertEq(hook.REBASING_LST(), E_ETH);
        assertEq(hook.WETH(), WETH_ADDR);
    }

    function test_rebalance_weETH_specific() public {
        vm.deal(address(this), 1 ether);
        hook.addWarmLiquidityETH{value: 0.5 ether}();
        _dealWeETH(address(this), 0.5 ether);
        IERC20(WE_ETH).approve(address(hook), 0.5 ether);
        hook.addWarmLiquidityLST(0.5 ether);

        for (uint256 i = 0; i < 3; i++) {
            _swapExactIn(0.03 ether, false);
        }

        uint256 lstVWId = Currency.wrap(address(hook.lstVaultWrapper())).toId();
        uint256 balBefore = poolManager.balanceOf(address(hook), lstVWId);

        weETHHook.rebalanceWarmLiquidity();

        uint256 balAfter = poolManager.balanceOf(address(hook), lstVWId);
        uint256 desired = hook.lstVWDesiredBalance();

        uint256 diffBefore = balBefore > desired ? balBefore - desired : desired - balBefore;
        uint256 diffAfter = balAfter > desired ? balAfter - desired : desired - balAfter;

        assertLt(diffAfter, diffBefore, "weETH rebalance should move closer to 50/50");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Obtain weETH via the ether.fi deposit adapter.
    /// @dev Uses a 30% ETH buffer because 1 weETH ≈ 1.09 ETH at this fork block.
    function _dealWeETH(address to, uint256 weETHAmount) internal {
        uint256 ethNeeded = (weETHAmount * 130) / 100 + 0.02 ether;
        vm.deal(address(this), ethNeeded);
        DEPOSIT_ADAPTER.depositETHForWeETH{value: ethNeeded}(address(0));
        uint256 bal = IERC20(WE_ETH).balanceOf(address(this));
        if (to != address(this)) {
            IERC20(WE_ETH).transfer(to, bal < weETHAmount ? bal : weETHAmount);
        }
    }
}
