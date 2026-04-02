// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SinglePairAssetSwapHook} from "src/periphery/SinglePairAssetSwapHook/SinglePairAssetSwapHook.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

/// @notice Deploys a SinglePairAssetSwapHook for a given vault wrapper pool key.
/// @dev The hook address must satisfy Uniswap v4 permission bit requirements. Callers must
///      mine a valid CREATE2 salt off-chain (e.g. via HookMiner.find) and pass it here.
///      The pool key's hooks field must be the yieldHarvestingHook, currency0 must be
///      vaultWrapper0, and currency1 must be vaultWrapper1.
contract SinglePairAssetSwapHookFactory {
    using PoolIdLibrary for PoolKey;

    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint160 public constant REQUIRED_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    IPoolManager public immutable poolManager;

    mapping(PoolId poolId => SinglePairAssetSwapHook hook) public hookForPool;

    event SinglePairAssetSwapHookCreated(bytes32 indexed poolId, address indexed hook);

    error InvalidHookAddress(address hook);
    error HookAlreadyExists(address hook);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Deploy a SinglePairAssetSwapHook for the given vault wrapper pool key and
    ///         initialize the corresponding raw-asset pool that uses the new hook.
    /// @param vaultWrapperPoolKey The pool key of the underlying vault wrapper pool.
    ///        hooks     = yieldHarvestingHook
    ///        currency0 = vaultWrapper0 (address-sorted: currency0 < currency1)
    ///        currency1 = vaultWrapper1
    /// @param salt A CREATE2 salt pre-mined so the resulting address has REQUIRED_FLAGS set.
    ///             Use HookMiner.find(address(this), REQUIRED_FLAGS, creationCode, constructorArgs) to find it.
    function create(PoolKey calldata vaultWrapperPoolKey, bytes32 salt)
        external
        returns (SinglePairAssetSwapHook hook, PoolKey memory assetPoolKey)
    {
        PoolId poolId = vaultWrapperPoolKey.toId();

        if (address(hookForPool[poolId]) != address(0)) {
            revert HookAlreadyExists(address(hookForPool[poolId]));
        }

        IERC4626 vaultWrapper0 = IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency0));
        IERC4626 vaultWrapper1 = IERC4626(Currency.unwrap(vaultWrapperPoolKey.currency1));

        hook = new SinglePairAssetSwapHook{salt: salt}(
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

        // Initialize the raw-asset pool (asset0/asset1) that routes through the new hook.
        // Sort assets since address order of vaultWrappers does not imply order of their assets.
        (address rawCurrency0, address rawCurrency1) = address(hook.asset0()) < address(hook.asset1())
            ? (address(hook.asset0()), address(hook.asset1()))
            : (address(hook.asset1()), address(hook.asset0()));

        assetPoolKey = PoolKey({
            currency0: Currency.wrap(rawCurrency0),
            currency1: Currency.wrap(rawCurrency1),
            fee: vaultWrapperPoolKey.fee,
            tickSpacing: vaultWrapperPoolKey.tickSpacing,
            hooks: hook
        });

        poolManager.initialize(assetPoolKey, SQRT_PRICE_1_1);

        emit SinglePairAssetSwapHookCreated(PoolId.unwrap(poolId), address(hook));
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
            HookMiner.find(address(this), REQUIRED_FLAGS, type(SinglePairAssetSwapHook).creationCode, constructorArgs);
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

        bytes32 initCodeHash = keccak256(abi.encodePacked(type(SinglePairAssetSwapHook).creationCode, constructorArgs));

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
