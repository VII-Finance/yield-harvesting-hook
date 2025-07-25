// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {Clones} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract YieldHarvestingHook is BaseHook {
    using StateLibrary for IPoolManager;

    address public immutable vaultWrapperImplementation;

    constructor(IPoolManager _manager) BaseHook(_manager) {
        vaultWrapperImplementation = address(new ERC4626VaultWrapper(address(this)));
    }

    modifier harvestAndDistributeYield(PoolKey calldata poolKey) {
        uint128 liquidity = poolManager.getLiquidity(poolKey.toId());

        if (liquidity != 0) {
            uint256 yield0 = _currencyToERC4626VaultWrapper(poolKey.currency0).pendingYield();
            uint256 yield1 = _currencyToERC4626VaultWrapper(poolKey.currency1).pendingYield();

            if (yield0 != 0 || yield1 != 0) {
                poolManager.donate(poolKey, yield0, yield1, "");

                if (yield0 != 0) {
                    poolManager.sync(poolKey.currency0);
                    _currencyToERC4626VaultWrapper(poolKey.currency0).harvest(address(poolManager));
                    poolManager.settle();
                }

                if (yield1 != 0) {
                    poolManager.sync(poolKey.currency1);
                    _currencyToERC4626VaultWrapper(poolKey.currency1).harvest(address(poolManager));
                    poolManager.settle();
                }
            }
        }

        _;
    }

    function initialize(PoolKey calldata poolKey, address underlyingVault0, address underlyingVault1) external {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(address, PoolKey calldata poolKey, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        harvestAndDistributeYield(poolKey)
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata poolKey, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        harvestAndDistributeYield(poolKey)
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata, bytes calldata)
        internal
        override
        harvestAndDistributeYield(poolKey)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _currencyToERC4626VaultWrapper(Currency currency) internal pure returns (ERC4626VaultWrapper) {
        return ERC4626VaultWrapper(Currency.unwrap(currency));
    }
}
