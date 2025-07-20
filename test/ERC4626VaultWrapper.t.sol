// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {FullMath} from "lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTKN", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC4626 is ERC4626 {
    constructor(MockERC20 asset) ERC4626(asset, "Mock ERC4626", "MERC4626") {}

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // solmate ERC4626 does not have phantom overflow protection
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : FullMath.mulDiv(assets, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : FullMath.mulDiv(shares, totalAssets(), supply);
    }
}

contract ERC4626VaultWrapperTest is ERC4626Test {
    address harvester = makeAddr("harvester");
    address harvestReceiver = makeAddr("harvestReceiver");
    MockERC4626 underlyingVault;

    function setUp() public override {
        _underlying_ = address(new MockERC20());
        underlyingVault = new MockERC4626(MockERC20(_underlying_));
        _vault_ = address(new ERC4626VaultWrapper(underlyingVault, harvester, "Vault Wrapper", "VW"));
        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    function setUpYield(Init memory init) public override {
        if (init.yield >= 0) {
            // gain
            uint256 gain = uint256(init.yield);
            //mint it to the underlying vault
            try MockERC20(_underlying_).mint(address(underlyingVault), gain) {
                //prank the harvestor and harvest to some address
                uint256 harvestReceiverBalanceBefore = ERC20(_vault_).balanceOf(harvestReceiver);
                vm.prank(harvester);
                ERC4626VaultWrapper(_vault_).harvest(harvestReceiver);

                assertEq(
                    ERC20(_vault_).balanceOf(harvestReceiver),
                    harvestReceiverBalanceBefore + gain,
                    "Harvest receiver balance should increase by the yield amount"
                );
            } catch {
                vm.assume(false);
            }
        } //we only support vaults that are ever increasing in value. i.e. lending protocols
    }

    modifier checkInvariants() {
        _;

        assertEq(ERC20(_underlying_).balanceOf(_vault_), 0, "Underlying asset balance in vault wrapper should be zero");

        assertEq(
            ERC4626VaultWrapper(_vault_).totalAssets(),
            underlyingVault.convertToAssets(underlyingVault.balanceOf(_vault_)),
            "Total assets in vault wrapper should equal underlying vault's converted assets"
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
