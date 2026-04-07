// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20, SmoothYieldVault} from "src/SmoothYieldVault.sol";


contract SmoothYieldVaultDeployment is Script {
    function run() external {
        IERC20 asset = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
        uint256 smoothingPeriod = 24 hours;
        address owner = 0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394;

        vm.startBroadcast();
        new SmoothYieldVault(asset, smoothingPeriod, owner);
        vm.stopBroadcast();
    }
}
