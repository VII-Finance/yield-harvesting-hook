// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapperTest} from "test/ERC4626VaultWrapper.t.sol";
import {AaveWrapper} from "src/vaultWrappers/AaveWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {ERC4626VaultWrapper} from "src/vaultWrappers/ERC4626VaultWrapper.sol";

//It tests ERC4626ness of AaveWrapper
//It's simple, just returns 1:1 every time
contract AaveWrapperERC4626nessTest is ERC4626VaultWrapperTest {
    address aaveWrapperImplementation = address(new AaveWrapper());

    function setUp() public virtual override {
        super.setUp();

        _vault_ = LibClone.cloneDeterministic(
            aaveWrapperImplementation,
            abi.encodePacked(address(this), harvester, address(underlyingVault)),
            keccak256(abi.encodePacked(address(underlyingVault), uint256(1))) //make sure salt in unique and not the same as the base test
        );
    }

    function setUpYield(Init memory init) public virtual override {
        if (init.yield > 0) {
            // gain
            uint256 gain = uint256(init.yield);

            //mint it to the underlying vault
            try underlyingAsset.mint(address(this), gain) {
                //we replicate the yield harvesting process for aave wrappers
                //we expect the balance of underlyingVault shares to be increased in case of aave
                underlyingAsset.approve(address(underlyingVault), gain);
                underlyingVault.deposit(gain, address(_vault_));

                //prank the harvestor and harvest
                uint256 harvestReceiverBalanceBefore = ERC20(_vault_).balanceOf(harvestReceiver);
                uint256 feeReceiverBalanceBefore = ERC20(_vault_).balanceOf(feeReceiver);

                assertEq(ERC4626VaultWrapper(_vault_).totalPendingYield(), gain);

                vm.prank(harvester);
                (uint256 actualHarvestedAssets, uint256 actualFees) = AaveWrapper(_vault_).harvest(harvestReceiver);

                uint256 profitForHarvester = gain;

                uint256 feeForFeeReceiver = profitForHarvester / ERC4626VaultWrapper(_vault_).feeDivisor();

                assertEq(actualHarvestedAssets, profitForHarvester - feeForFeeReceiver);
                assertEq(actualFees, feeForFeeReceiver);

                assertEq(
                    ERC20(_vault_).balanceOf(feeReceiver),
                    feeReceiverBalanceBefore + feeForFeeReceiver,
                    "Fee receiver balance should increase by the fee amount"
                );

                assertEq(
                    ERC20(_vault_).balanceOf(harvestReceiver),
                    harvestReceiverBalanceBefore + profitForHarvester - feeForFeeReceiver,
                    "Harvest receiver balance should increase by the yield amount"
                );
            } catch {
                vm.assume(false);
            }
        } //we know in aave there is no bad debt socialization, so we don't need to handle losses
    }
}
