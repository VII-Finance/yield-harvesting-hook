// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapperHookFactory} from "src/ERC4626VaultWrapperHookFactory.sol";
import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract ERC4626VaultWrapperHookFactoryTest is Test {
    address harvester = makeAddr("harvester");
    address poolManager = makeAddr("poolManager");
    ERC4626VaultWrapperHookFactory factory;

    function setUp() public {
        factory = new ERC4626VaultWrapperHookFactory(IPoolManager(poolManager), harvester);
    }

    function test_createVaultWrapper() public {
        address vaultAddress = address(new MockERC4626(new MockERC20()));
        address assetAddress = address(ERC4626(vaultAddress).asset());

        address expectedWrapperAddress = factory.getVaultWrapperAddress(vaultAddress);

        vm.expectEmit();
        emit ERC4626VaultWrapperHookFactory.VaultWrapperCreated(vaultAddress, expectedWrapperAddress);

        ERC4626VaultWrapper wrapper = factory.createVaultWrapper(ERC4626(vaultAddress));

        assertEq(address(wrapper), expectedWrapperAddress);
        assertEq(wrapper.yieldHarvester(), harvester);
        assertEq(wrapper.name(), factory.getWrapperName(ERC4626(vaultAddress)));
        assertEq(wrapper.symbol(), factory.getWrapperSymbol(ERC4626(vaultAddress)));
        assertEq(address(wrapper.asset()), assetAddress);
    }
}
