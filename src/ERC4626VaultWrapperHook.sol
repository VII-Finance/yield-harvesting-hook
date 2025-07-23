// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/**
 * @notice This vault wrapper is intended for use with lending protocol vaults where the underlying vault share price monotonically increases.
 * @dev If the underlying vault share price drops, this vault may become insolvent. In cases of bad debt socialization within the lending protocol vaults, the share price can decrease.
 *      It is recommended to have an insurance fund capable of burning tokens to restore solvency if needed.
 *      No harvest operations will occur until the vault regains solvency.
 */
contract ERC4626VaultWrapperHook is BaseHook, ERC4626 {
    using SafeCast for uint256;
    using SafeTransferLib for ERC20;

    address public immutable yieldHarvestingHook;

    error NotYieldHarvester();

    constructor(
        IPoolManager _poolManager,
        ERC4626 _underlyingVault,
        address _yieldHarvestingHook,
        string memory _name,
        string memory _symbol
    ) BaseHook(_poolManager) ERC4626(_underlyingVault, _name, _symbol) {
        yieldHarvestingHook = _yieldHarvestingHook;
    }

    //make sure no one can initialize with this hook

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        BeforeSwapDelta returnDelta;
        bool isExactInput = params.amountSpecified < 0;

        uint256 amountIn;
        uint256 amountOut;

        (address tokenIn, address tokenOut) = params.zeroForOne
            ? (_currencyToAddress(key.currency0), _currencyToAddress(key.currency1))
            : (_currencyToAddress(key.currency1), _currencyToAddress(key.currency0));

        if (tokenIn == address(asset) && tokenOut == address(this)) {
            if (isExactInput) {
                amountIn = uint256(-params.amountSpecified);
                //we take the underlying Vault shares of amountIn from the user and mint them ERC20s equivalent to it's asset amount
                amountOut = previewDeposit(amountIn);
            } else {
                //to be able to mint the users amountOut of ERC20s, how much shares we should be taking from them
                amountOut = uint256(params.amountSpecified);
                amountIn = previewMint(amountOut);
            }

            //we take the underlying Vault shares from the manager
            poolManager.take(_addressToCurrency(tokenIn), address(this), amountIn);
            //we mint the poolManager the amountOut of this ERC20
            poolManager.sync(_addressToCurrency(tokenOut));
            _mint(address(poolManager), amountOut);
            poolManager.settle();
        } else if (tokenIn == address(this) && tokenOut == address(asset)) {
            if (isExactInput) {
                // user want to burn amountIn of this ERC20, how much of underlying vault shares would they get back?
                amountIn = uint256(-params.amountSpecified);
                amountOut = previewRedeem(amountIn);
            } else {
                // user want to get amountOut of underlying vault shares, how much of this ERC20 they need to burn?
                amountOut = uint256(params.amountSpecified);
                amountIn = previewWithdraw(amountOut);
            }

            //we take amountIn of ERC20 from the pool Manager and burn it
            poolManager.take(_addressToCurrency(tokenIn), address(this), amountIn);
            _burn(address(this), amountIn);

            poolManager.sync(_addressToCurrency(tokenOut));
            asset.safeTransfer(address(poolManager), amountOut);
            poolManager.settle();
        }

        returnDelta = isExactInput
            ? toBeforeSwapDelta(amountIn.toInt128(), -(amountOut.toInt128()))
            : toBeforeSwapDelta(-(amountOut.toInt128()), amountIn.toInt128());

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function _addressToCurrency(address token) internal pure returns (Currency) {
        return Currency.wrap(token);
    }

    function _currencyToAddress(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return ERC4626(address(asset)).previewWithdraw(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return ERC4626(address(asset)).previewMint(assets);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return ERC4626(address(asset)).previewRedeem(assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return ERC4626(address(asset)).previewDeposit(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return ERC4626(address(asset)).convertToAssets(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return ERC4626(address(asset)).convertToShares(shares);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address) public view override returns (uint256) {
        return ERC4626(address(asset)).maxMint(address(this));
    }

    function maxMint(address) public view override returns (uint256) {
        return ERC4626(address(asset)).maxDeposit(address(this));
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return min(ERC4626(address(asset)).maxWithdraw(address(this)), balanceOf[owner]);
    }

    function pendingYield() public view returns (uint256) {
        uint256 maxWithdrawableAssets = ERC4626(address(asset)).maxWithdraw(address(this));
        if (maxWithdrawableAssets > totalSupply) {
            return maxWithdrawableAssets - totalSupply;
        }
        return 0;
    }

    function harvest(address to) external returns (uint256 harvestedAssets) {
        if (msg.sender != yieldHarvestingHook) revert NotYieldHarvester();
        harvestedAssets = pendingYield();
        _mint(to, harvestedAssets);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
