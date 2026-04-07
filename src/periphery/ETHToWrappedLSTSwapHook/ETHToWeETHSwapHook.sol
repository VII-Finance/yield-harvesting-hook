// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ETHToWrappedLSTSwapHookBase} from "src/periphery/ETHToWrappedLSTSwapHook/ETHToWrappedLSTSwapHookBase.sol";

interface IWeETH {
    function wrap(uint256 _eETHAmount) external returns (uint256);
    function unwrap(uint256 _weETHAmount) external returns (uint256);
    function getWeETHByeETH(uint256 _eETHAmount) external view returns (uint256);
    function getEETHByWeETH(uint256 _weETHAmount) external view returns (uint256);
}

/// @notice Hook enabling native ETH ↔ weETH swaps routed through a VII vault wrapper pool
///         (WETH vault wrapper ↔ eETH vault wrapper).
///
/// @dev weETH uses ether.fi-specific wrap/unwrap rather than standard ERC4626 deposit/redeem.
contract ETHToWeETHSwapHook is ETHToWrappedLSTSwapHookBase {
    address public constant E_ETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant WE_ETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    constructor(
        IPoolManager _poolManager,
        IERC4626 _wethVault,
        IERC4626 _eETHVault,
        IERC4626 _wethVaultWrapper,
        IERC4626 _eETHVaultWrapper,
        IHooks _yieldHarvestingHook,
        uint24 _fee,
        int24 _tickSpacing
    )
        ETHToWrappedLSTSwapHookBase(
            _poolManager,
            _wethVault,
            _eETHVault,
            _wethVaultWrapper,
            _eETHVaultWrapper,
            E_ETH,
            WE_ETH,
            _yieldHarvestingHook,
            _fee,
            _tickSpacing
        )
    {}

    // ── LST conversion primitives ────────────────────────────────────────────

    function _rebaseToWrapped(uint256 eETHAmount) internal override returns (uint256) {
        return IWeETH(WE_ETH).wrap(eETHAmount);
    }

    function _wrappedToRebase(uint256 weETHAmount) internal override returns (uint256) {
        return IWeETH(WE_ETH).unwrap(weETHAmount);
    }

    function _getWrappedByRebase(uint256 eETHAmount) internal view override returns (uint256) {
        return IWeETH(WE_ETH).getWeETHByeETH(eETHAmount);
    }

    function _getRebaseByWrapped(uint256 weETHAmount) internal view override returns (uint256) {
        return IWeETH(WE_ETH).getEETHByWeETH(weETHAmount);
    }
}
