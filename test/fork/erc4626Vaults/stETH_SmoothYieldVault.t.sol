// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/BaseVaultsTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {SmoothYieldVault} from "src/SmoothYieldVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

contract SmoothYieldVaultsTest is BaseVaultsTest {
    address constant stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    uint256 constant smoothingPeriod = 1 days;
    SmoothYieldVault stETHSmoothYieldVault;

    function setUp() public virtual override {
        super.setUp();
        stETHSmoothYieldVault = new SmoothYieldVault(IERC20(stETH), 1 days, address(this));
    }

    function setUpVaults(bool) public override {
        super.setUpVaults(false);
    }

    function _getUnderlyingVaults() internal view override returns (MockERC4626, MockERC4626) {
        return (
            MockERC4626(address(stETHSmoothYieldVault)),
            MockERC4626(0xBEEf050ecd6a16c4e7bfFbB52Ebba7846C4b8cD4) //stake house WETH (https://app.morpho.org/ethereum/vault/0xBEEf050ecd6a16c4e7bfFbB52Ebba7846C4b8cD4/steakhouse-eth)
        );
    }

    function _getMixedAssetsInfo() internal view override returns (MockERC4626, MockERC20) {
        return
            (
                MockERC4626(address(stETHSmoothYieldVault)),
                MockERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) //WETH
            );
    }

    function _getInitialPrice() internal view override returns (uint160) {
        return _getCurrentPrice(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27); // v4 ETH/USDC 0.05% pool
    }

    //deal for stETH on forked environment doesn't work so we have to handle it specially
    function deal(address token, address to, uint256 give) internal override {
        if (token == stETH) {
            vm.deal(address(this), give + 10);
            ILido(stETH).submit{value: give + 10}(address(0));
            IERC20(stETH).transfer(to, give + 5);
        } else {
            super.deal(token, to, give);
        }
    }
}
