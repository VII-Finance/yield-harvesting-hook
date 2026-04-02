// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {UnderlyingAssetsSwapHook} from "src/periphery/UnderlyingAssetsSwapHook/UnderlyingAssetsSwapHook.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

/// @notice Deploys a UnderlyingAssetsSwapHook for a given vault wrapper pool key.
/// @dev The hook address must satisfy Uniswap v4 permission bit requirements. Callers must
///      mine a valid CREATE2 salt off-chain (e.g. via HookMiner.find) and pass it here.
///      The pool key's hooks field must be the yieldHarvestingHook, currency0 must be
///      vaultWrapper0, and currency1 must be vaultWrapper1.
contract UnderlyingAssetsSwapHookFactory {
    using PoolIdLibrary for PoolKey;

    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint160 public constant REQUIRED_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    IPoolManager public immutable poolManager;

    mapping(PoolId poolId => UnderlyingAssetsSwapHook hook) public hookForPool;

    event UnderlyingAssetsSwapHookCreated(bytes32 indexed poolId, address indexed hook);

    error InvalidHookAddress(address hook);
    error HookAlreadyExists(address hook);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Deploy a UnderlyingAssetsSwapHook for the given vault wrapper pool key and
    ///         initialize the corresponding raw-asset pool that uses the new hook.
    /// @param vaultWrapperPoolKey The pool key of the underlying vault wrapper pool.
    ///        hooks     = yieldHarvestingHook
    ///        currency0 = vaultWrapper0 (address-sorted: currency0 < currency1)
    ///        currency1 = vaultWrapper1
    /// @param salt A CREATE2 salt pre-mined so the resulting address has REQUIRED_FLAGS set.
    ///             Use HookMiner.find(address(this), REQUIRED_FLAGS, creationCode, constructorArgs) to find it.
    function create(PoolKey calldata vaultWrapperPoolKey, bytes32 salt)
        external
        returns (UnderlyingAssetsSwapHook hook, PoolKey memory assetPoolKey)
    {
        PoolId poolId = vaultWrapperPoolKey.toId();

        if (address(hookForPool[poolId]) != address(0)) {
            revert HookAlreadyExists(address(hookForPool[poolId]));
        }

        IERC4626 vaultWrapper0 = IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency0));
        IERC4626 vaultWrapper1 = IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency1));

        hook = new UnderlyingAssetsSwapHook{salt: salt}(
            poolManager,
            vaultWrapperPoolKey.hooks,
            vaultWrapper0,
            vaultWrapper1,
            vaultWrapperPoolKey.fee,
            vaultWrapperPoolKey.tickSpacing,
            address(this)
        );

        if (uint160(address(hook)) & REQUIRED_FLAGS != REQUIRED_FLAGS) {
            revert InvalidHookAddress(address(hook));
        }

        hookForPool[poolId] = hook;

        assetPoolKey = _buildAssetPoolKey(hook);

        poolManager.initialize(assetPoolKey, SQRT_PRICE_1_1);

        emit UnderlyingAssetsSwapHookCreated(PoolId.unwrap(poolId), address(hook));
    }

    /// @dev Derives the asset pool key from a deployed hook's immutables.
    ///      Assets are sorted by address (Uniswap v4 requirement: currency0 < currency1).
    function _buildAssetPoolKey(UnderlyingAssetsSwapHook hook) internal view returns (PoolKey memory) {
        (address rawCurrency0, address rawCurrency1) = address(hook.asset0()) < address(hook.asset1())
            ? (address(hook.asset0()), address(hook.asset1()))
            : (address(hook.asset1()), address(hook.asset0()));

        return PoolKey({
            currency0: Currency.wrap(rawCurrency0),
            currency1: Currency.wrap(rawCurrency1),
            fee: hook.fee(),
            tickSpacing: hook.tickSpacing(),
            hooks: hook
        });
    }

    /// @notice Mine a CREATE2 salt whose resulting address satisfies REQUIRED_FLAGS.
    /// @dev This is a view function but may be gas-intensive; call off-chain.
    function findSalt(PoolKey calldata vaultWrapperPoolKey) external view returns (address hookAddress, bytes32 salt) {
        bytes memory constructorArgs = abi.encode(
            poolManager,
            vaultWrapperPoolKey.hooks,
            IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency0)),
            IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency1)),
            vaultWrapperPoolKey.fee,
            vaultWrapperPoolKey.tickSpacing,
            address(this)
        );

        (hookAddress, salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(UnderlyingAssetsSwapHook).creationCode, constructorArgs);
    }

    /// @notice Returns the asset pool key for a given vault wrapper pool id.
    function assetPoolKeyForPool(PoolId poolId) public view returns (PoolKey memory) {
        return _buildAssetPoolKey(hookForPool[poolId]);
    }

    /// @notice Returns the asset pool key for a given vault wrapper pool key.
    function assetPoolKeyForPool(PoolKey memory vaultWrapperPoolKey) external view returns (PoolKey memory) {
        return assetPoolKeyForPool(vaultWrapperPoolKey.toId());
    }

    /// @notice Predict the hook address for a given pool key and salt without deploying.
    function predict(PoolKey calldata vaultWrapperPoolKey, bytes32 salt) external view returns (address) {
        IERC4626 vaultWrapper0 = IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency0));
        IERC4626 vaultWrapper1 = IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency1));

        bytes memory constructorArgs = abi.encode(
            poolManager,
            vaultWrapperPoolKey.hooks,
            vaultWrapper0,
            vaultWrapper1,
            vaultWrapperPoolKey.fee,
            vaultWrapperPoolKey.tickSpacing,
            address(this)
        );

        bytes32 initCodeHash = keccak256(abi.encodePacked(type(UnderlyingAssetsSwapHook).creationCode, constructorArgs));

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
