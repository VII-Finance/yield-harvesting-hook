// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/vaultWrappers/ERC4626VaultWrapper.sol";
import {BaseVaultWrapper} from "src/vaultWrappers/base/BaseVaultWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {BaseAssetToVaultWrapperHelper} from "src/periphery/base/BaseAssetToVaultWrapperHelper.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {ERC4626VaultWrapperTest} from "test/ERC4626VaultWrapper.t.sol";

contract MockAssetToVaultWrapperHelper is BaseAssetToVaultWrapperHelper {
    function deposit(
        IERC4626 vaultWrapper,
        address underlyingVault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver
    ) external returns (uint256) {
        return _deposit(vaultWrapper, underlyingVault, asset, from, amount, receiver);
    }

    function redeem(IERC4626 vaultWrapper, address underlyingVault, address from, uint256 amount, address receiver)
        external
        returns (uint256)
    {
        return _redeem(vaultWrapper, underlyingVault, from, amount, receiver);
    }

    function mint(
        IERC4626 vaultWrapper,
        address underlyingVault,
        IERC20 asset,
        address from,
        uint256 amount,
        address receiver
    ) external returns (uint256) {
        return _mint(vaultWrapper, underlyingVault, asset, from, amount, receiver);
    }

    function withdraw(IERC4626 vaultWrapper, address underlyingVault, address from, uint256 amount, address receiver)
        external
        returns (uint256)
    {
        return _withdraw(vaultWrapper, underlyingVault, from, amount, receiver);
    }
}

contract AssetToVaultWrapperHelper is Test {
    MockERC20 underlyingAsset;
    MockERC4626 underlyingVault;
    ERC4626VaultWrapper vaultWrapper;
    MockAssetToVaultWrapperHelper assetToVaultWrapperHelper;

    address harvester = makeAddr("harvester");
    address user = makeAddr("user");
    address receiver = makeAddr("receiver");

    function setUp() public {
        underlyingAsset = new MockERC20();
        underlyingVault = new MockERC4626(underlyingAsset);
        vaultWrapper = ERC4626VaultWrapper(
            LibClone.cloneDeterministic(
                address(new ERC4626VaultWrapper()),
                abi.encodePacked(address(this), harvester, address(underlyingVault)),
                keccak256(abi.encodePacked(address(underlyingVault)))
            )
        );

        assetToVaultWrapperHelper = new MockAssetToVaultWrapperHelper();
    }

    function _depositForUser(uint256 amount, address from, address to) internal returns (uint256 sharesReceived) {
        vm.startPrank(from);
        underlyingAsset.approve(address(assetToVaultWrapperHelper), amount);
        sharesReceived = assetToVaultWrapperHelper.deposit(
            vaultWrapper, address(underlyingVault), IERC20(address(underlyingAsset)), from, amount, to
        );
        vm.stopPrank();
    }

    function test_deposit(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        underlyingAsset.mint(user, amount);

        uint256 userInitialBalance = underlyingAsset.balanceOf(user);
        uint256 receiverInitialBalance = vaultWrapper.balanceOf(receiver);

        uint256 sharesReceived = _depositForUser(amount, user, receiver);

        assertEq(underlyingAsset.balanceOf(user), userInitialBalance - amount);
        assertEq(vaultWrapper.balanceOf(receiver), receiverInitialBalance + sharesReceived);
    }

    function test_redeem(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        underlyingAsset.mint(user, amount);

        uint256 sharesReceived = _depositForUser(amount, user, user);

        uint256 receiverInitialBalance = underlyingAsset.balanceOf(receiver);
        uint256 userInitialBalance = vaultWrapper.balanceOf(user);

        vm.startPrank(user);
        vaultWrapper.approve(address(assetToVaultWrapperHelper), sharesReceived);
        uint256 assetsReceived =
            assetToVaultWrapperHelper.redeem(vaultWrapper, address(underlyingVault), user, sharesReceived, receiver);
        vm.stopPrank();

        assertEq(underlyingAsset.balanceOf(receiver), receiverInitialBalance + assetsReceived);
        assertEq(vaultWrapper.balanceOf(user), userInitialBalance - sharesReceived);
    }

    function test_mint(uint256 shares) public {
        shares = bound(shares, 1, type(uint128).max);

        uint256 underlyingVaultSharesRequired = vaultWrapper.previewMint(shares);
        uint256 assetsRequired = underlyingVault.previewMint(underlyingVaultSharesRequired);
        underlyingAsset.mint(user, assetsRequired);

        uint256 userInitialBalance = underlyingAsset.balanceOf(user);
        uint256 receiverInitialBalance = vaultWrapper.balanceOf(receiver);

        vm.startPrank(user);
        underlyingAsset.approve(address(assetToVaultWrapperHelper), assetsRequired);
        uint256 actualAssetsRequired = assetToVaultWrapperHelper.mint(
            vaultWrapper, address(underlyingVault), IERC20(address(underlyingAsset)), user, shares, receiver
        );
        vm.stopPrank();

        assertEq(actualAssetsRequired, assetsRequired);
        assertEq(underlyingAsset.balanceOf(user), userInitialBalance - assetsRequired);
        assertEq(vaultWrapper.balanceOf(receiver), receiverInitialBalance + shares);
    }

    function test_withdraw(uint256 assets) public {
        assets = bound(assets, 1, type(uint128).max);
        underlyingAsset.mint(user, assets);

        uint256 sharesReceived = _depositForUser(assets, user, user);

        uint256 receiverInitialBalance = underlyingAsset.balanceOf(receiver);
        uint256 userInitialBalance = vaultWrapper.balanceOf(user);

        vm.startPrank(user);
        vaultWrapper.approve(address(assetToVaultWrapperHelper), sharesReceived);
        uint256 assetsWithdrawn =
            assetToVaultWrapperHelper.withdraw(vaultWrapper, address(underlyingVault), user, assets, receiver);
        vm.stopPrank();

        assertEq(assetsWithdrawn, assets);
        assertEq(underlyingAsset.balanceOf(receiver), receiverInitialBalance + assetsWithdrawn);
        assertEq(vaultWrapper.balanceOf(user), userInitialBalance - sharesReceived);
    }
}