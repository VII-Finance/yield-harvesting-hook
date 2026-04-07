// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ETHToWrappedLSTSwapHookBase} from "src/periphery/ETHToWrappedLSTSwapHookBase.sol";

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256 wstETHAmount);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);
}

/// @notice Hook enabling native ETH ↔ wstETH swaps routed through a VII vault wrapper pool
///         (WETH vault wrapper ↔ stETH vault wrapper).
contract ETHToWstETHSwapHook is ETHToWrappedLSTSwapHookBase {
    address public constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    constructor(
        IPoolManager _poolManager,
        IERC4626 _wethVault,
        IERC4626 _stETHVault,
        IERC4626 _wethVaultWrapper,
        IERC4626 _stETHVaultWrapper,
        IHooks _yieldHarvestingHook,
        uint24 _fee,
        int24 _tickSpacing,
        uint160 _initialSqrtPriceX96
    )
        ETHToWrappedLSTSwapHookBase(
            _poolManager,
            _wethVault,
            _stETHVault,
            _wethVaultWrapper,
            _stETHVaultWrapper,
            ST_ETH,
            WST_ETH,
            _yieldHarvestingHook,
            _fee,
            _tickSpacing,
            _initialSqrtPriceX96
        )
    {}

    // ── LST conversion primitives ────────────────────────────────────────────

    function _rebaseToWrapped(uint256 stETHAmount) internal override returns (uint256) {
        return IWstETH(WST_ETH).wrap(stETHAmount);
    }

    function _wrappedToRebase(uint256 wstETHAmount) internal override returns (uint256) {
        return IWstETH(WST_ETH).unwrap(wstETHAmount);
    }

    function _getWrappedByRebase(uint256 stETHAmount) internal view override returns (uint256) {
        return IWstETH(WST_ETH).getWstETHByStETH(stETHAmount);
    }

    function _getRebaseByWrapped(uint256 wstETHAmount) internal view override returns (uint256) {
        return IWstETH(WST_ETH).getStETHByWstETH(wstETHAmount);
    }
}
