// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {ERC4626VaultWrapperFactory} from "src/ERC4626VaultWrapperFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

contract YieldHarvestingHookScript is Script {
    uint160 constant HOOK_PERMISSIONS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address owner = 0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394;
        IPoolManager poolManager = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

        (, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, HOOK_PERMISSIONS, type(YieldHarvestingHook).creationCode, abi.encode(owner, poolManager)
        );

        new YieldHarvestingHook{salt: salt}(owner, poolManager);
    }
}
