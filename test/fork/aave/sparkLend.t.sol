// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVaultsTest} from "test/fork/BaseVaultsTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/interfaces/IAToken.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IATokenWithPool is IAToken {
    //This method is exposed by actual aTokens but it isn't in IAToken interface
    function POOL() external view returns (address);
}

contract SparkLendTest is BaseVaultsTest {
    function setUpVaults(bool) public override {
        super.setUpVaults(true);
    }

    function _getUnderlyingVaults() internal pure override returns (MockERC4626, MockERC4626) {
        return (
            MockERC4626(0xC02aB1A5eaA8d1B114EF786D9bde108cD4364359),
            MockERC4626(0x59cD1C87501baa753d0B5B5Ab5D8416A45cD71DB)
        ); //spark lend spUSDS, spWETH
    }

    function _getMixedAssetsInfo() internal pure override returns (MockERC4626, MockERC20) {
        return (
            MockERC4626(0x12B54025C112Aa61fAce2CDB7118740875A566E9), //spark lend spWstETH
            MockERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) //WETH
        );
    }

    function _getInitialPrice() internal view override returns (uint160) {
        return _getCurrentPrice(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27); // v4 ETH/USDC 0.05% pool
    }

    function _deposit(MockERC4626 vault, uint256 amount, address to) internal override returns (uint256) {
        IAToken aToken = IAToken(address(vault));
        address underlyingAsset = aToken.UNDERLYING_ASSET_ADDRESS();
        IPool pool = IPool(IATokenWithPool(address(aToken)).POOL());

        deal(underlyingAsset, address(this), amount);
        MockERC20(underlyingAsset).approve(address(pool), amount);

        uint256 aTokenBalanceBefore = aToken.balanceOf(to);

        pool.supply(underlyingAsset, amount, to, 0);

        assertApproxEqAbs(
            aToken.balanceOf(to) - aTokenBalanceBefore,
            amount,
            2,
            "AToken balance after supply should be equal to the amount supplied"
        );

        return aToken.balanceOf(to) - aTokenBalanceBefore;
    }
}
