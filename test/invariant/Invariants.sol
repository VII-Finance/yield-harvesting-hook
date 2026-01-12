// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";
import {Handler} from "test/invariant/Handler.sol";
import {BaseVaultWrapper} from "src/vaultWrappers/base/BaseVaultWrapper.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";

contract Invariants is Test {
    Handler public handler;

    function setUp() public {
        handler = new Handler();
        handler.setUp();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.addLiquidity.selector;
        selectors[1] = handler.removeLiquidity.selector;
        selectors[2] = handler.directMintVaultWrapper.selector;
        selectors[3] = handler.directWithdrawVaultWrapper.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_check_solvency() public {
        //  BaseVaultWrapper vaultWrapper = handler.vaultWrapper0();
        //   MockERC4626 underlyingVault = handler.underlyingVault0();

        //   uint256 underlyingVaultBalance = underlyingVault.balanceOf(address(vaultWrapper));

        //   assertLe()
    }
}
