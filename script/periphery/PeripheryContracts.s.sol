// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AssetToAssetSwapHookForERC4626} from "src/periphery/AssetToAssetSwapHookForERC4626.sol";
import {LiquidityHelper} from "src/periphery/LiquidityHelper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";

contract PeripheryContractsScript is Script {
    uint160 constant HOOK_PERMISSIONS = uint160(Hooks.BEFORE_SWAP_FLAG) | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address owner = 0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394;
        IPoolManager poolManager = IPoolManager(0x1F98400000000000000000000000000000000004);

        address evc = 0x2A1176964F5D7caE5406B627Bf6166664FE83c60;
        IPositionManager positionManager = IPositionManager(0x4529A01c7A0410167c5740C487A8DE60232617bf);
        YieldHarvestingHook yieldHarvestingHook = YieldHarvestingHook(address(0));

        // Deploy AssetToAssetSwapHookForERC4626
        (, bytes32 assetToAssetSalt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_PERMISSIONS,
            type(AssetToAssetSwapHookForERC4626).creationCode,
            abi.encode(poolManager, yieldHarvestingHook, owner)
        );
        vm.startBroadcast();

        AssetToAssetSwapHookForERC4626 assetToAssetSwapHook =
            new AssetToAssetSwapHookForERC4626{salt: assetToAssetSalt}(poolManager, yieldHarvestingHook, owner);

        // Deploy LiquidityHelper
        LiquidityHelper liquidityHelper = new LiquidityHelper(evc, positionManager, yieldHarvestingHook);

        vm.stopBroadcast();
    }
}
