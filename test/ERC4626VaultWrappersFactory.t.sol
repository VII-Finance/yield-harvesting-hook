// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {ERC4626VaultWrappersFactory} from "src/ERC4626VaultWrappersFactory.sol";
import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTKN", 18) {}
}

contract MockERC4626Vault is ERC4626 {
    constructor() ERC4626(ERC20(address(new MockERC20())), "Mock Token", "MTKN") {}

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

contract ERC4626VaultWrappersFactoryAltTest is Test {
    address harvester = makeAddr("harvester");
    ERC4626VaultWrappersFactory factory;

    function setUp() public {
        factory = new ERC4626VaultWrappersFactory(harvester);
    }

    function testCreateVaultWrapper() public {
        address vaultAddress = address(new MockERC4626Vault());
        address assetAddress = address(ERC4626(vaultAddress).asset());

        address expectedWrapperAddress =
            factory.getVaultWrapperAddress(vaultAddress, factory.vaultWrappersCount(vaultAddress));

        vm.expectEmit();
        emit ERC4626VaultWrappersFactory.VaultWrapperCreated(assetAddress, vaultAddress, expectedWrapperAddress);

        ERC4626VaultWrapper wrapper = factory.createVaultWrapper(ERC4626(vaultAddress));

        assertEq(address(wrapper), expectedWrapperAddress);
        assertEq(wrapper.yieldHarvester(), harvester);
        assertEq(wrapper.name(), "Mock Token");
        assertEq(wrapper.symbol(), "MTKN");
        assertEq(address(wrapper.asset()), assetAddress);

        assertEq(factory.vaultWrappersCount(vaultAddress), 1);
    }
}
