// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/Base/BaseVaultsTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";

contract EulerVaultsTest is BaseVaultsTest {
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
}
