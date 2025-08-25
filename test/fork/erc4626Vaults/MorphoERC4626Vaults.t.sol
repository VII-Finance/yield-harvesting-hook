// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/BaseVaultsTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";

contract MorphoVaultsTest is BaseVaultsTest {
    function setUpVaults(bool) public override {
        super.setUpVaults(false);
    }

    function _getUnderlyingVaults() internal pure override returns (MockERC4626, MockERC4626) {
        return (
            MockERC4626(0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB), //stake house USDC (https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc)
            MockERC4626(0xBEEf050ecd6a16c4e7bfFbB52Ebba7846C4b8cD4) //stake house WETH (https://app.morpho.org/ethereum/vault/0xBEEf050ecd6a16c4e7bfFbB52Ebba7846C4b8cD4/steakhouse-eth)
        );
    }

    function _getMixedAssetsInfo() internal pure override returns (MockERC4626, MockERC20) {
        return (
            MockERC4626(0x9a8bC3B04b7f3D87cfC09ba407dCED575f2d61D8), //Mev capital WETH (https://app.morpho.org/ethereum/vault/0x9a8bC3B04b7f3D87cfC09ba407dCED575f2d61D8/mev-capital-weth)
            MockERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) //WETH
        );
    }

    function _getInitialPrice() internal view override returns (uint160) {
        return _getCurrentPrice(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27); // v4 ETH/USDC 0.05% pool
    }
}
