// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IVaultWrapper} from "src/interfaces/IVaultWrapper.sol";
import {ERC4626VaultWrapperFactory} from "src/ERC4626VaultWrapperFactory.sol";

contract YieldHarvestingHook is BaseHook {
    using StateLibrary for IPoolManager;

    address public immutable erc4626VaultWrapperFactory;

    error NotFactory();

    constructor(address _owner, IPoolManager _manager, address _aavePool) BaseHook(_manager) {
        erc4626VaultWrapperFactory = address(new ERC4626VaultWrapperFactory(_owner, _manager, address(this), _aavePool));
    }

    modifier harvestAndDistributeYield(PoolKey calldata poolKey) {
        uint128 liquidity = poolManager.getLiquidity(poolKey.toId());

        if (liquidity != 0) {
            uint256 yield0 = _getPendingYield(poolKey.currency0);
            uint256 yield1 = _getPendingYield(poolKey.currency1);

            if (yield0 != 0 || yield1 != 0) {
                poolManager.donate(poolKey, yield0, yield1, "");

                if (yield0 != 0) {
                    poolManager.sync(poolKey.currency0);
                    _currencyToVaultWrapper(poolKey.currency0).harvest(address(poolManager));
                    poolManager.settle();
                }

                if (yield1 != 0) {
                    poolManager.sync(poolKey.currency1);
                    _currencyToVaultWrapper(poolKey.currency1).harvest(address(poolManager));
                    poolManager.settle();
                }
            }
        }

        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
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

    /// @notice Ensures that only the ERC4626 vault wrapper factory can initialize a pool with this hook
    function _beforeInitialize(address caller, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (caller != erc4626VaultWrapperFactory) {
            revert NotFactory();
        }
        return this.beforeInitialize.selector;
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

    function _getPendingYield(Currency currency) internal view returns (uint256) {
        IVaultWrapper vaultWrapper = _currencyToVaultWrapper(currency);

        try vaultWrapper.pendingYield() returns (uint256 pendingYield, uint256) {
            return pendingYield;
        } catch {
            return 0; // The call is expected to fail if it's not a vault wrapper
        }
    }

    function _currencyToVaultWrapper(Currency currency) internal pure returns (IVaultWrapper) {
        return IVaultWrapper(Currency.unwrap(currency));
    }
}
