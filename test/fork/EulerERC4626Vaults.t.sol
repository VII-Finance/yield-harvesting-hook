// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {YieldHarvestingHookTest} from "test/YieldHarvestingHook.t.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {BaseVaultWrapper} from "src/VaultWrappers/Base/BaseVaultWrapper.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract EulerVaultsTest is YieldHarvestingHookTest {
    address POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _getPoolManager() internal view override returns (PoolManager) {
        return PoolManager(POOL_MANAGER);
    }

    function setUp() public virtual override {
        string memory fork_url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(fork_url); //every time, this will fork at the latest block to test against the latest state

        super.setUp();
    }

    function setUpVaults(bool) public override {
        super.setUpVaults(false);
    }

    function _getUnderlyingVaults() internal pure override returns (MockERC4626, MockERC4626) {
        return (
            MockERC4626(0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2),
            MockERC4626(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9)
        ); //euler prime eWETH, eUSDC
    }

    function _getMixedAssetsInfo() internal pure override returns (MockERC4626, MockERC20) {
        return (
            MockERC4626(0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1), //euler prime eWstETH
            MockERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) //WETH
        );
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
