// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {BaseAssetToVaultWrapperHelper} from "src/periphery/base/BaseAssetToVaultWrapperHelper.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";

interface IPositionManagerExtended is IPositionManager {
    function WETH9() external view returns (address);
}

///@dev This doesn't support aave vaults. Only vault wrappers that have underlying vaults that support ERC4626 interface are supported
contract LiquidityHelper is EVCUtil, BaseAssetToVaultWrapperHelper {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    IPositionManager public immutable positionManager;
    /// @notice The hooks contract for vault wrapper pools
    IHooks public immutable yieldHarvestingHook;
    IWETH9 public immutable weth;

    error NotOwner();

    constructor(address _evc, IPositionManager _positionManager, IHooks _yieldHarvestingHook) EVCUtil(_evc) {
        yieldHarvestingHook = _yieldHarvestingHook;
        positionManager = _positionManager;
        weth = IWETH9(IPositionManagerExtended(address(_positionManager)).WETH9());
    }

    modifier onlyOwnerOf(uint256 tokenId) {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != _msgSender()) {
            revert NotOwner();
        }
        _;
    }

    function _pullAndConvertAssets(
        PoolKey memory poolKey,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal returns (PoolKey memory, uint128, uint128) {
        (IERC4626 vaultWrapper0, IERC4626 vaultWrapper1) = hookData.length == 0
            ? (IERC4626(address(0)), IERC4626(address(0)))
            : abi.decode(hookData, (IERC4626, IERC4626));
        if (amount0Max != 0) {
            if (!poolKey.currency0.isAddressZero()) {
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(_msgSender(), address(this), amount0Max);
            } else if (msg.value == 0) {
                weth.transferFrom(_msgSender(), address(this), amount0Max);
            }
        }
        if (amount1Max != 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(_msgSender(), address(this), amount1Max);
        }

        uint256 currentWETHBalance = weth.balanceOf(address(this));
        if (currentWETHBalance > 0) {
            weth.withdraw(currentWETHBalance);
        }

        amount0Max = SafeCast.toUint128(poolKey.currency0.balanceOf(address(this)));
        amount1Max = SafeCast.toUint128(poolKey.currency1.balanceOf(address(this)));

        if (address(vaultWrapper0) != address(0)) {
            IERC4626 underlyingVault0 = _getUnderlyingVault(vaultWrapper0);
            _deposit(
                vaultWrapper0,
                address(underlyingVault0),
                IERC20(Currency.unwrap(poolKey.currency0)),
                address(this),
                amount0Max,
                address(positionManager)
            );
            poolKey.currency0 = Currency.wrap(address(vaultWrapper0));
            poolKey.hooks = yieldHarvestingHook;
        } else {
            if (!poolKey.currency0.isAddressZero()) {
                poolKey.currency0.transfer(address(positionManager), amount0Max);
            }
        }

        if (address(vaultWrapper1) != address(0)) {
            IERC4626 underlyingVault1 = _getUnderlyingVault(vaultWrapper1);
            _deposit(
                vaultWrapper1,
                address(underlyingVault1),
                IERC20(Currency.unwrap(poolKey.currency1)),
                address(this),
                amount1Max,
                address(positionManager)
            );
            poolKey.currency1 = Currency.wrap(address(vaultWrapper1));
            poolKey.hooks = yieldHarvestingHook;
        } else {
            poolKey.currency1.transfer(address(positionManager), amount1Max);
        }

        //currencies might be out of order at this point, so we need to sort them
        if (Currency.unwrap(poolKey.currency0) > Currency.unwrap(poolKey.currency1)) {
            (poolKey.currency0, poolKey.currency1) = (poolKey.currency1, poolKey.currency0);
            (amount0Max, amount1Max) = (amount1Max, amount0Max);
        }

        return (poolKey, amount0Max, amount1Max);
    }

    function _callModifyLiquidity(
        uint8 actionType, // either Actions.MINT_POSITION or Actions.INCREASE_LIQUIDITY
        bytes memory actionData, // encoded params for first action,
        PoolKey memory poolKey
    ) internal {
        bytes memory actions = new bytes(5);
        actions[0] = bytes1(actionType);
        actions[1] = bytes1(uint8(Actions.SETTLE));
        actions[2] = bytes1(uint8(Actions.SETTLE));
        actions[3] = bytes1(uint8(Actions.SWEEP));
        actions[4] = bytes1(uint8(Actions.SWEEP));

        bytes[] memory params = new bytes[](5);
        params[0] = actionData;
        params[1] = abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false);
        params[3] = abi.encode(poolKey.currency0, _msgSender());
        params[4] = abi.encode(poolKey.currency1, _msgSender());

        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp);
    }

    function mintPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) external payable returns (uint256 tokenId) {
        tokenId = positionManager.nextTokenId();

        (poolKey, amount0Max, amount1Max) = _pullAndConvertAssets(poolKey, amount0Max, amount1Max, hookData);

        bytes memory actionData =
            abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, "");

        _callModifyLiquidity(uint8(Actions.MINT_POSITION), actionData, poolKey);
    }

    function increaseLiquidity(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) external payable onlyOwnerOf(tokenId) {
        (poolKey, amount0Max, amount1Max) = _pullAndConvertAssets(poolKey, amount0Max, amount1Max, hookData);

        bytes memory actionData = abi.encode(tokenId, liquidity, amount0Max, amount1Max, "");
        _callModifyLiquidity(uint8(Actions.INCREASE_LIQUIDITY), actionData, poolKey);
    }

    function decreaseLiquidity(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint128 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        address recipient,
        bytes calldata hookData
    ) public onlyOwnerOf(tokenId) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        (IERC4626 vaultWrapper0, IERC4626 vaultWrapper1) = hookData.length == 0
            ? (IERC4626(address(0)), IERC4626(address(0)))
            : abi.decode(hookData, (IERC4626, IERC4626));

        if (address(vaultWrapper0) != address(0)) {
            poolKey.currency0 = Currency.wrap(address(vaultWrapper0));
            poolKey.hooks = yieldHarvestingHook;
        }
        if (address(vaultWrapper1) != address(0)) {
            poolKey.currency1 = Currency.wrap(address(vaultWrapper1));
            poolKey.hooks = yieldHarvestingHook;
        }

        if (Currency.unwrap(poolKey.currency0) > Currency.unwrap(poolKey.currency1)) {
            (poolKey.currency0, poolKey.currency1) = (poolKey.currency1, poolKey.currency0);
        }

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);

        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp);

        //this contract will have the tokens after decreasing liquidity, now we need to withdraw from vault wrappers if needed and send to recipient
        if (address(vaultWrapper0) != address(0)) {
            IERC4626 underlyingVault0 = _getUnderlyingVault(vaultWrapper0);
            _redeem(
                vaultWrapper0,
                address(underlyingVault0),
                address(this),
                vaultWrapper0.balanceOf(address(this)),
                recipient
            );
        } else {
            //simply transfer the tokens to recipient
            currency0.transfer(recipient, currency0.balanceOfSelf());
        }

        if (address(vaultWrapper1) != address(0)) {
            IERC4626 underlyingVault1 = _getUnderlyingVault(vaultWrapper1);
            _redeem(
                vaultWrapper1,
                address(underlyingVault1),
                address(this),
                vaultWrapper1.balanceOf(address(this)),
                recipient
            );
        } else {
            //simply transfer the tokens to recipient
            currency1.transfer(recipient, currency1.balanceOfSelf());
        }
    }

    function collectFees(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint128 amount0Min,
        uint128 amount1Min,
        address recipient,
        bytes calldata hookData
    ) external {
        decreaseLiquidity(poolKey, tokenId, 0, amount0Min, amount1Min, recipient, hookData);
    }
}
