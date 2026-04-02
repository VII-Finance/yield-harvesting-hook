// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseAssetSwapHookForkTest} from "test/fork/BaseAssetSwapHookForkTest.t.sol";
import {SinglePairAssetSwapHook} from "src/periphery/SinglePairAssetSwapHook/SinglePairAssetSwapHook.sol";
import {SinglePairAssetSwapHookFactory} from "src/periphery/SinglePairAssetSwapHook/SinglePairAssetSwapHookFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract SinglePairAssetSwapHookForkTest is BaseAssetSwapHookForkTest {
    SinglePairAssetSwapHookFactory public factory;
    SinglePairAssetSwapHook public hook;

    function _deployHookAndInitPool() internal override {
        factory = new SinglePairAssetSwapHookFactory(poolManager);

        (address vw0, address vw1) = address(vaultWrapper0) < address(vaultWrapper1)
            ? (address(vaultWrapper0), address(vaultWrapper1))
            : (address(vaultWrapper1), address(vaultWrapper0));

        PoolKey memory vaultWrapperPoolKey = PoolKey({
            currency0: Currency.wrap(vw0),
            currency1: Currency.wrap(vw1),
            fee: 18,
            tickSpacing: 1,
            hooks: IHooks(address(yieldHarvestingHook))
        });

        (, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);

        (hook, assetsPoolKey) = factory.create(vaultWrapperPoolKey, salt);
    }

    // _hookDataForExactIn returns "" (base default) — no hookData needed
    // _setupBeforeExactOut is a no-op (base default) — vault wrappers are fixed at construction
}
