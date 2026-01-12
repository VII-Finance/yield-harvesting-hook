// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";
import {Handler} from "test/invariant/Handler.sol";
import {BaseVaultWrapper} from "src/vaultWrappers/base/BaseVaultWrapper.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract Invariants is Test {
    Handler public handler;

    function setUp() public {
        handler = new Handler();
        handler.setUp();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.addLiquidity.selector;
        selectors[1] = handler.removeLiquidity.selector;
        selectors[2] = handler.mintIntoUnderlyingVault.selector;
        selectors[3] = handler.depositIntoVaultWrapper.selector;
        selectors[4] = handler.withdrawFromVaultWrapper.selector;
        selectors[5] = handler.redeemFromVaultWrapper.selector;
        selectors[6] = handler.mintIntoUnderlyingVault.selector;
        selectors[7] = handler.depositIntoUnderlyingVault.selector;
        selectors[8] = handler.withdrawFromUnderlyingVault.selector;
        selectors[9] = handler.redeemFromUnderlyingVault.selector;
        selectors[10] = handler.donateToUnderlyingVault.selector;
        selectors[11] = handler.donateToVaultWrapper.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }
    
    function checkVaultWrapperSolvency(IERC4626 vaultWrapper) internal view {
        IERC4626 underlyingVault = IERC4626(vaultWrapper.asset());
        assertLe(
            vaultWrapper.totalSupply(), underlyingVault.previewRedeem(underlyingVault.balanceOf(address(vaultWrapper)))
        );
    }
    // total supply of vault wrappers should always be less than the worth of underlying vault share balance in asset terms
    function invariant_check_solvency() public view {
        checkVaultWrapperSolvency(IERC4626(address(handler.vaultWrapper0())));
        checkVaultWrapperSolvency(IERC4626(address(handler.vaultWrapper1())));
    }
}
