// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {YieldHarvestingHookTest} from "test/YieldHarvestingHook.t.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract BaseVaultsTest is YieldHarvestingHookTest {
    address POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _getPoolManager() internal view override returns (PoolManager) {
        return PoolManager(POOL_MANAGER);
    }

    function setUp() public virtual override {
        string memory fork_url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(fork_url); //every time, this will fork at the latest block to test against the latest state

        super.setUp();
    }

    function _mintYieldToVaults(uint256 yield0, uint256 yield1) internal override returns (uint256, uint256) {
        uint256 timeToIncrease = bound(yield0, 1, 604800 * 2); //2 week in seconds
        vm.warp(block.timestamp + timeToIncrease);

        (yield0,) = vaultWrapper0.pendingYield();
        (yield1,) = vaultWrapper1.pendingYield();

        return (yield0, yield1);
    }

    function _mintYieldToMixedVault(uint256 vaultYield) internal override returns (uint256) {
        uint256 timeToIncrease = bound(vaultYield, 1, 604800 * 2); //2 week in seconds
        vm.warp(block.timestamp + timeToIncrease);

        (vaultYield,) = mixedVaultWrapper.pendingYield();

        return vaultYield;
    }

    receive() external payable {
        // Allow receiving ETH for testing purposes
    }
}
