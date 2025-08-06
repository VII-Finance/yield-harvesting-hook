// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/Base/BaseVaultsTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/interfaces/IAToken.sol";

interface IATokenWithPool is IAToken {
    //This method is exposed by actual aTokens but it isn't in IAToken interface
    function POOL() external view returns (address);
}

contract AaveVaultsTest is BaseVaultsTest {
    function setUpVaults(bool) public override {
        super.setUpVaults(true);
    }

    function _getUnderlyingVaults() internal pure override returns (MockERC4626, MockERC4626) {
        return (
            MockERC4626(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8),
            MockERC4626(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c)
        ); //aave v3 aWETH, aUSDC
    }

    function _getMixedAssetsInfo() internal pure override returns (MockERC4626, MockERC20) {
        return (
            MockERC4626(0x0B925eD163218f6662a35e0f0371Ac234f9E9371), //aave v3 aWstETH
            MockERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) //WETH
        );
    }

    function _deposit(MockERC4626 vault, uint256 amount, address to) internal override returns (uint256) {
        IAToken aToken = IAToken(address(vault));
        address underlyingAsset = aToken.UNDERLYING_ASSET_ADDRESS();
        IPool pool = IPool(IATokenWithPool(address(aToken)).POOL());

        deal(underlyingAsset, address(this), amount);
        MockERC20(underlyingAsset).approve(address(pool), amount);

        pool.supply(underlyingAsset, amount, to, 0);

        return amount;
    }
}
