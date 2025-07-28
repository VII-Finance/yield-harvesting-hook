// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {FullMath} from "lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol";

contract ERC4626VaultWrapperTest is ERC4626Test {
    address harvester = makeAddr("harvester");
    address harvestReceiver = makeAddr("harvestReceiver");
    MockERC4626 underlyingVault;
    MockERC20 underlyingAsset;

    uint160 hookPermissionCount = 14;
    uint160 clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    function setUp() public virtual override {
        underlyingAsset = new MockERC20();
        underlyingVault = new MockERC4626(underlyingAsset);
        _underlying_ = address(underlyingVault);

        _vault_ = address(new ERC4626VaultWrapper(harvester));
        ERC4626VaultWrapper(_vault_).initialize(address(underlyingVault), "Vault Wrapper", "VW");

        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    function setUpVault(Init memory init) public virtual override {
        // setup initial shares and assets for individual users
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];
            vm.assume(_isEOA(user));
            vm.assume(user != address(0));
            // shares
            uint256 shares = init.share[i];

            shares = bound(shares, 2, underlyingAsset.totalSupply() + 2);
            //mint underlying assets
            underlyingAsset.mint(user, shares);
            vm.startPrank(user);
            // approve underlying vault to spend assets
            underlyingAsset.approve(address(underlyingVault), shares);
            // deposit assets into underlying vault
            uint256 underlyingVaultSharesMinted = underlyingVault.deposit(shares, user);
            // approve vault wrapper to spend shares
            underlyingVault.approve(_vault_, underlyingVaultSharesMinted);
            // mint shares in vault wrapper
            ERC4626VaultWrapper(_vault_).deposit(underlyingVaultSharesMinted, user);
            vm.stopPrank();

            uint256 assets = init.asset[i];
            assets = bound(assets, 2, underlyingAsset.totalSupply());

            underlyingAsset.mint(user, assets);
            vm.startPrank(user);
            // approve underlying vault to spend assets
            underlyingAsset.approve(address(underlyingVault), assets);
            underlyingVault.deposit(assets, user);

            vm.stopPrank();
        }

        // setup initial yield for vault
        setUpYield(init);
    }

    function setUpYield(Init memory init) public virtual override {
        if (init.yield >= 0) {
            // gain
            uint256 gain = uint256(init.yield);

            //mint it to the underlying vault
            try underlyingAsset.mint(address(underlyingVault), gain) {
                //prank the harvestor and harvest
                uint256 harvestReceiverBalanceBefore = ERC20(_vault_).balanceOf(harvestReceiver);
                vm.prank(harvester);
                ERC4626VaultWrapper(_vault_).harvest(harvestReceiver);

                uint256 profitForHarvester = FullMath.mulDiv(
                    ERC4626VaultWrapper(_vault_).totalAssets(), gain, ERC4626(address(underlyingVault)).totalSupply()
                );

                assertEq(
                    ERC20(_vault_).balanceOf(harvestReceiver),
                    harvestReceiverBalanceBefore + profitForHarvester,
                    "Harvest receiver balance should increase by the yield amount"
                );
            } catch {
                vm.assume(false);
            }
        } //we only support vaults that are ever increasing in value. i.e. lending protocols
    }

    modifier checkInvariants() {
        _;

        assertEq(underlyingAsset.balanceOf(_vault_), 0, "Underlying asset balance in vault wrapper should be zero");

        assertLe(
            ERC4626VaultWrapper(_vault_).totalSupply(),
            underlyingVault.convertToAssets(underlyingVault.balanceOf(_vault_)),
            "Total vault shares minted should be equal to actual assets underlying vault shares are worth"
        );
    }

    function test_asset(Init memory init) public virtual override checkInvariants {
        super.test_asset(init);
    }

    function test_totalAssets(Init memory init) public virtual override checkInvariants {
        super.test_totalAssets(init);
    }

    function test_convertToShares(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_convertToShares(init, assets);
    }

    function test_convertToAssets(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_convertToAssets(init, shares);
    }

    function test_maxDeposit(Init memory init) public virtual override checkInvariants {
        super.test_maxDeposit(init);
    }

    function test_previewDeposit(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_previewDeposit(init, assets);
    }

    function test_deposit(Init memory init, uint256 assets, uint256 allowance)
        public
        virtual
        override
        checkInvariants
    {
        super.test_deposit(init, assets, allowance);
    }

    function test_maxMint(Init memory init) public virtual override checkInvariants {
        super.test_maxMint(init);
    }

    function test_previewMint(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_previewMint(init, shares);
    }

    function test_mint(Init memory init, uint256 shares, uint256 allowance) public virtual override checkInvariants {
        super.test_mint(init, shares, allowance);
    }

    function test_maxWithdraw(Init memory init) public virtual override checkInvariants {
        super.test_maxWithdraw(init);
    }

    function test_previewWithdraw(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_previewWithdraw(init, assets);
    }

    function test_withdraw(Init memory init, uint256 assets, uint256 allowance)
        public
        virtual
        override
        checkInvariants
    {
        super.test_withdraw(init, assets, allowance);
    }

    function test_withdraw_zero_allowance(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_withdraw_zero_allowance(init, assets);
    }

    function test_maxRedeem(Init memory init) public virtual override checkInvariants {
        super.test_maxRedeem(init);
    }

    function test_previewRedeem(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_previewRedeem(init, shares);
    }

    function test_redeem(Init memory init, uint256 shares, uint256 allowance) public virtual override checkInvariants {
        super.test_redeem(init, shares, allowance);
    }

    function test_redeem_zero_allowance(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_redeem_zero_allowance(init, shares);
    }

    function test_RT_deposit_redeem(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_RT_deposit_redeem(init, assets);
    }

    function test_RT_deposit_withdraw(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_RT_deposit_withdraw(init, assets);
    }

    function test_RT_redeem_deposit(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_RT_redeem_deposit(init, shares);
    }

    function test_RT_redeem_mint(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_RT_redeem_mint(init, shares);
    }

    function test_RT_mint_withdraw(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_RT_mint_withdraw(init, shares);
    }

    function test_RT_mint_redeem(Init memory init, uint256 shares) public virtual override checkInvariants {
        super.test_RT_mint_redeem(init, shares);
    }

    function test_RT_withdraw_mint(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_RT_withdraw_mint(init, assets);
    }

    function test_RT_withdraw_deposit(Init memory init, uint256 assets) public virtual override checkInvariants {
        super.test_RT_withdraw_deposit(init, assets);
    }
}
