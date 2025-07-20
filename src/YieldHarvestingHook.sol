// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

contract YieldHarvestingHook is BaseHook {
    mapping(address asset => uint256 count) public vaultWrappersCreated;

    event VaultWrapperCreated(address indexed asset, address indexed vault, address indexed vaultWrapper);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function createVaultWrapper(ERC4626 vault) external returns (ERC4626VaultWrapper vaultWrapper) {
        ERC20 asset = vault.asset();
        bytes32 salt = keccak256(abi.encodePacked(address(vault), vaultWrappersCreated[address(asset)]));

        //TODO: figure out names and symbols that makes sense and are immutable
        vaultWrapper = new ERC4626VaultWrapper{salt: salt}(vault, address(this), asset.name(), asset.symbol());
        vaultWrappersCreated[address(asset)]++;

        emit VaultWrapperCreated(address(asset), address(vault), address(vaultWrapper));
    }

    modifier harvestAndDistributeYield(PoolKey calldata pool) {
        uint256 harvested0 = _currencyToERC4626VaultWrapper(pool.currency0).harvest(address(poolManager));

        poolManager.sync(pool.currency0);

        uint256 harvested1 = _currencyToERC4626VaultWrapper(pool.currency1).harvest(address(poolManager));

        poolManager.sync(pool.currency1);

        poolManager.donate(pool, harvested0, harvested1, "");

        poolManager.settle();

        _;
    }

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

    function _afterAddLiquidity(
        address,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override harvestAndDistributeYield(poolKey) returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
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
