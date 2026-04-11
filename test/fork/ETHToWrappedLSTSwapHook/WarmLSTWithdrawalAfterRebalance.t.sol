// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ETHToWrappedLSTSwapHookBaseTest} from "test/fork/ETHToWrappedLSTSwapHook/ETHToWrappedLSTSwapHookBaseTest.t.sol";
import {ETHToWstETHSwapHook, IWstETH} from "src/periphery/ETHToWrappedLSTSwapHook/ETHToWstETHSwapHook.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

/// forge-config: default.fuzz.runs = 1
contract WarmLSTWithdrawalAfterRebalanceTest is ETHToWrappedLSTSwapHookBaseTest {
    address constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    ETHToWstETHSwapHook public wstETHHook;

    function _rebasingLSTAddress() internal pure override returns (address) {
        return ST_ETH;
    }

    function _wrappedLSTAddress() internal pure override returns (address) {
        return WST_ETH;
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
            int24(60)
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(ETHToWstETHSwapHook).creationCode, constructorArgs);

        wstETHHook = new ETHToWstETHSwapHook{salt: salt}(
            poolManager,
            IERC4626(EULER_WETH_VAULT),
            IERC4626(address(lstSmoothVault)),
            wethVW,
            lstVW,
            IHooks(address(yieldHarvestingHook)),
            3000,
            60
        );

        hook = wstETHHook;

        assetPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(WST_ETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(wstETHHook))
        });
    }

    function _dealWrappedLST(address to, uint256 amount) internal override {
        _dealWstETH(to, amount);
    }

    function _dealDustToHook() internal override {
        _dealStETH(address(hook), 0.001 ether);
        deal(WETH_ADDR, address(hook), 0.001 ether);
    }

    function deal(address token, address to, uint256 give) internal override {
        if (token == ST_ETH) {
            vm.deal(address(this), give + 10);
            ILido(ST_ETH).submit{value: give + 10}(address(0));
            IERC20(ST_ETH).transfer(to, give);
        } else {
            super.deal(token, to, give);
        }
    }

    function test_removeWarmLiquidityLST_revertsAfterRebalance() public {
        uint256 amount = 0.5 ether;
        uint256 half = amount / 2;

        // Step 1: Add warm liquidity on LST side.
        _dealWrappedLST(address(this), amount);
        IERC20(WST_ETH).approve(address(hook), amount);
        hook.addWarmLiquidityLST(amount);

        // Step 2: Introduce smooth-vault yield and move time forward.
        deal(ST_ETH, address(lstSmoothVault), 0.1 ether);
        vm.warp(block.timestamp + 2 days + 1);

        // Step 3: Rebalance burns idle wrapped-LST claims to top up vault-wrapper side.
        hook.rebalanceWarmLiquidity();

        uint256 idleWrappedClaims = poolManager.balanceOf(address(hook), Currency.wrap(WST_ETH).toId());
        assertLt(idleWrappedClaims, amount - half, "rebalance should consume wrapped-LST idle claims");

        // Step 4: Withdrawal now reverts because removal still assumes original 50/50 split.
        vm.expectRevert();
        hook.removeWarmLiquidityLST(amount);
    }

    function test_removeWarmLiquidityETH_revertsAfterRebalance() public {
        uint256 amount = 0.5 ether;
        uint256 half = amount / 2;

        // Step 1: Add warm liquidity on ETH side.
        vm.deal(address(this), amount);
        hook.addWarmLiquidityETH{value: amount}();

        // Step 2: Introduce smooth-vault yield and move time forward.
        deal(ST_ETH, address(lstSmoothVault), 0.1 ether);
        vm.warp(block.timestamp + 2 days + 1);

        // Step 3: Rebalance burns idle ETH claims to top up vault-wrapper side.
        hook.rebalanceWarmLiquidity();

        uint256 idleETHClaims = poolManager.balanceOf(address(hook), Currency.wrap(address(0)).toId());
        assertLt(idleETHClaims, amount - half, "rebalance should consume ETH idle claims");

        // Step 4: Withdrawal now reverts because removal still assumes original 50/50 split.
        vm.expectRevert();
        hook.removeWarmLiquidityETH(amount);
    }

    function _dealStETH(address to, uint256 amount) internal {
        vm.deal(address(this), amount + 10);
        ILido(ST_ETH).submit{value: amount + 10}(address(0));
        if (to != address(this)) IERC20(ST_ETH).transfer(to, amount);
    }

    function _dealWstETH(address to, uint256 wstETHAmount) internal {
        uint256 stETHNeeded = IWstETH(WST_ETH).getStETHByWstETH(wstETHAmount) + 10;
        _dealStETH(address(this), stETHNeeded);
        IERC20(ST_ETH).approve(WST_ETH, stETHNeeded);
        IWstETH(WST_ETH).wrap(stETHNeeded);
        if (to != address(this)) IERC20(WST_ETH).transfer(to, wstETHAmount);
    }
}
