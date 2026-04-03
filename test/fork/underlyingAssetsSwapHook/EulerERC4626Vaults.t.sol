// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {
    BaseUnderlyingAssetsSwapHookTest
} from "test/fork/underlyingAssetsSwapHook/BaseUnderlyingAssetsSwapHookTest.t.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {SmoothYieldVault} from "src/SmoothYieldVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

interface IDepositAdapter {
    function depositETHForWeETH(address _referral) external payable returns (uint256);
}

interface IWeETH {
    function unwrap(uint256 amount) external returns (uint256);
}

contract EulerVaultsUnderlyingAssetsSwapTest is BaseUnderlyingAssetsSwapHookTest {
    function _getUnderlyingVaults() internal pure override returns (MockERC4626, MockERC4626) {
        return (
            MockERC4626(0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2),
            MockERC4626(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9)
        ); //euler prime eWETH, eUSDC
    }

    function setUpVaults(bool) public override {
        // Always use ERC4626-style wrappers (no Aave)
        super.setUpVaults(false);
    }

    /// @dev Override to pin the fork to a different block (e.g. when testing vaults
    ///      deployed after the default block).
    function _getForkBlock() internal pure override returns (uint256) {
        return 23101344;
    }

    function _getInitialPrice() internal view override returns (uint160) {
        return _getCurrentPrice(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27); // v4 ETH/USDC 0.05% pool
    }
}
