// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC4626VaultWrapperFactory} from "src/ERC4626VaultWrapperFactory.sol";
import {BaseVaultWrapper, ERC4626VaultWrapper} from "src/VaultWrappers/ERC4626VaultWrapper.sol";
import {AaveWrapper} from "src/VaultWrappers/AaveWrapper.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

contract MockAToken {
    function UNDERLYING_ASSET_ADDRESS() external pure returns (address) {
        return address(0);
    }

    function name() external pure returns (string memory) {
        return "Mock AToken";
    }

    function symbol() external pure returns (string memory) {
        return "aToken";
    }
}

contract MockERC4626 {
    function asset() external pure returns (address) {
        return address(0);
    }

    function name() external pure returns (string memory) {
        return "Mock ERC4626";
    }

    function symbol() external pure returns (string memory) {
        return "mERC4626";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract ERC4626VaultWrapperFactoryTest is Test {
    using StateLibrary for PoolManager;

    using PoolIdLibrary for PoolKey;

    ERC4626VaultWrapperFactory factory;
    PoolManager public poolManager;
    address poolManagerOwner = makeAddr("poolManagerOwner");
    YieldHarvestingHook yieldHarvestingHook;
    address factoryOwner = makeAddr("factoryOwner");

    address tokenA;
    address tokenB;
    MockERC4626 vaultA;
    MockERC4626 vaultB;
    MockAToken aTokenA;
    MockAToken aTokenB;

    uint160 hookPermissionCount = 14;
    uint160 clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_X96 = 79228162514264337593543950336; // 1:1 price

    uint160 constant HOOK_PERMISSIONS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

    event PoolInitialized(PoolKey key, uint160 sqrtPriceX96, int24 tick);

    function setUp() public {
        poolManager = new PoolManager(poolManagerOwner);

        (, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_PERMISSIONS,
            type(YieldHarvestingHook).creationCode,
            abi.encode(factoryOwner, poolManager)
        );

        yieldHarvestingHook = new YieldHarvestingHook{salt: salt}(factoryOwner, poolManager);

        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
        vaultA = new MockERC4626();
        vaultB = new MockERC4626();

        aTokenA = new MockAToken();
        aTokenB = new MockAToken();

        factory = ERC4626VaultWrapperFactory(yieldHarvestingHook.erc4626VaultWrapperFactory());
    }

    function isPoolInitialized(PoolKey memory poolKey) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        return sqrtPriceX96 != 0;
    }

    function testConstructor() public view {
        assertEq(address(factory.poolManager()), address(poolManager));
        assertEq(factory.yieldHarvestingHook(), address(address(yieldHarvestingHook)));
        assertTrue(factory.vaultWrapperImplementation() != address(0));
        assertTrue(factory.aaveWrapperImplementation() != address(0));
    }

    function testCreateERC4626VaultPool() public {
        (ERC4626VaultWrapper wrapperA, ERC4626VaultWrapper wrapperB) = factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        assertTrue(address(wrapperA) != address(0));
        assertTrue(address(wrapperB) != address(0));
        assertTrue(address(wrapperA) != address(wrapperB));

        assertEq(wrapperA.asset(), address(vaultA));
        assertEq(wrapperB.asset(), address(vaultB));

        PoolKey memory key = _buildPoolKey(address(wrapperA), address(wrapperB));
        assertTrue(isPoolInitialized(key), "Pool should be initialized");
    }

    function testCreateERC4626VaultToTokenPool() public {
        ERC4626VaultWrapper wrapper = factory.createERC4626VaultToTokenPool(
            IERC4626(address(vaultA)), address(tokenA), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        assertTrue(address(wrapper) != address(0));
        assertEq(wrapper.asset(), address(vaultA));
        assertEq(wrapper.name(), "VII Finance Wrapped Mock ERC4626");
        assertEq(wrapper.symbol(), "VII-mERC4626");

        PoolKey memory key = _buildPoolKey(address(wrapper), address(tokenA));
        assertTrue(isPoolInitialized(key), "Pool should be initialized");
    }

    function testCreateAaveToERC4626Pool() public {
        (AaveWrapper aaveWrapper, ERC4626VaultWrapper vaultWrapper) = factory.createAaveToERC4626Pool(
            address(aTokenA), IERC4626(address(vaultA)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        assertTrue(address(aaveWrapper) != address(0));
        assertTrue(address(vaultWrapper) != address(0));
        assertEq(aaveWrapper.asset(), address(aTokenA));
        assertEq(vaultWrapper.asset(), address(vaultA));

        PoolKey memory key = _buildPoolKey(address(aaveWrapper), address(vaultWrapper));
        assertTrue(isPoolInitialized(key), "Pool should be initialized");
    }

    function testCreateAaveToTokenPool() public {
        AaveWrapper aaveWrapper =
            factory.createAaveToTokenPool(address(aTokenA), address(tokenA), FEE, TICK_SPACING, SQRT_PRICE_X96);

        assertTrue(address(aaveWrapper) != address(0));
        assertEq(aaveWrapper.asset(), address(aTokenA));

        PoolKey memory key = _buildPoolKey(address(aaveWrapper), address(tokenA));
        assertTrue(isPoolInitialized(key), "Pool should be initialized");
    }

    function testCreateAavePool() public {
        (AaveWrapper aaveWrapperA, AaveWrapper aaveWrapperB) =
            factory.createAavePool(address(aTokenA), address(aTokenB), FEE, TICK_SPACING, SQRT_PRICE_X96);

        assertTrue(address(aaveWrapperA) != address(0));
        assertTrue(address(aaveWrapperB) != address(0));
        assertTrue(address(aaveWrapperA) != address(aaveWrapperB));
        assertEq(aaveWrapperA.asset(), address(aTokenA));
        assertEq(aaveWrapperB.asset(), address(aTokenB));

        PoolKey memory key = _buildPoolKey(address(aaveWrapperA), address(aaveWrapperB));
        assertTrue(isPoolInitialized(key), "Pool should be initialized");
    }

    function testDeterministicAddresses() public {
        factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        vm.expectRevert();
        factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );
    }

    function testCurrencyOrdering() public {
        (ERC4626VaultWrapper wrapperA, ERC4626VaultWrapper wrapperB) = factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        PoolKey memory key = _buildPoolKey(address(wrapperA), address(wrapperB));

        assertTrue(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1));
    }

    function testMultiplePools() public {
        factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        factory.createERC4626VaultToTokenPool(
            IERC4626(address(vaultA)), address(tokenA), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        factory.createAaveToTokenPool(address(aTokenA), address(tokenB), FEE, TICK_SPACING, SQRT_PRICE_X96);
    }

    function testPredictVaultWrapperAddress() public {
        bytes32 salt = _generateSalt(address(vaultA), address(vaultB), FEE, TICK_SPACING);

        address predicted = LibClone.predictDeterministicAddress(
            factory.vaultWrapperImplementation(),
            _generateImmutableArgsForVaultWrapper(address(vaultA)),
            salt,
            address(factory)
        );

        (ERC4626VaultWrapper wrapperA,) = factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        assertEq(address(wrapperA), predicted, "Predicted address should match deployed address");
    }

    function testPredictAaveWrapperAddress() public {
        bytes32 salt = _generateSalt(address(aTokenA), address(vaultA), FEE, TICK_SPACING);

        address predicted = LibClone.predictDeterministicAddress(
            factory.aaveWrapperImplementation(),
            _generateImmutableArgsForAaveWrapper(address(aTokenA)),
            salt,
            address(factory)
        );

        (AaveWrapper aaveWrapper,) = factory.createAaveToERC4626Pool(
            address(aTokenA), IERC4626(address(vaultA)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        assertEq(address(aaveWrapper), predicted, "Predicted address should match deployed address");
    }

    function testPredictMultipleWrapperAddresses() public {
        bytes32 vaultSalt = _generateSalt(address(vaultA), address(tokenA), FEE, TICK_SPACING);
        address predictedVault = LibClone.predictDeterministicAddress(
            factory.vaultWrapperImplementation(),
            _generateImmutableArgsForVaultWrapper(address(vaultA)),
            vaultSalt,
            address(factory)
        );

        bytes32 aaveSalt = _generateSalt(address(aTokenA), address(tokenB), FEE, TICK_SPACING);
        address predictedAave = LibClone.predictDeterministicAddress(
            factory.aaveWrapperImplementation(),
            _generateImmutableArgsForAaveWrapper(address(aTokenA)),
            aaveSalt,
            address(factory)
        );

        ERC4626VaultWrapper vaultWrapper = factory.createERC4626VaultToTokenPool(
            IERC4626(address(vaultA)), address(tokenA), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        AaveWrapper aaveWrapper =
            factory.createAaveToTokenPool(address(aTokenA), address(tokenB), FEE, TICK_SPACING, SQRT_PRICE_X96);

        assertEq(address(vaultWrapper), predictedVault, "Vault wrapper prediction should match");
        assertEq(address(aaveWrapper), predictedAave, "Aave wrapper prediction should match");
    }

    function testSetFeeParameters() public {
        (AaveWrapper aaveWrapper, ERC4626VaultWrapper vaultWrapper) = factory.createAaveToERC4626Pool(
            address(aTokenA), IERC4626(address(vaultA)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        assertEq(aaveWrapper.feeDivisor(), 0);
        assertEq(aaveWrapper.feeReceiver(), address(0));
        assertEq(vaultWrapper.feeDivisor(), 0);
        assertEq(vaultWrapper.feeReceiver(), address(0));

        vm.expectRevert(BaseVaultWrapper.NotFactory.selector);
        aaveWrapper.setFeeParameters(20, makeAddr("feeReceiver"));

        vm.expectRevert();
        factory.configureWrapperFees(address(aaveWrapper), 20, makeAddr("feeReceiver"));

        //setting fee divisor less than 14 should fail
        //this means the max fees that owner can take is 7.14%
        //and they can only get fees 1/14 = 7.14% 1/15 = 6.67%, 1/16 = 6.25% etc.
        vm.expectRevert(BaseVaultWrapper.InvalidFeeParams.selector);
        vm.startPrank(factoryOwner);
        factory.configureWrapperFees(address(aaveWrapper), 13, makeAddr("feeReceiver"));

        factory.configureWrapperFees(address(aaveWrapper), 14, makeAddr("feeReceiver"));
        assertEq(aaveWrapper.feeDivisor(), 14);
        assertEq(aaveWrapper.feeReceiver(), makeAddr("feeReceiver"));

        factory.configureWrapperFees(address(vaultWrapper), 14, makeAddr("feeReceiver"));
        assertEq(vaultWrapper.feeDivisor(), 14);
        assertEq(vaultWrapper.feeReceiver(), makeAddr("feeReceiver"));

        vm.stopPrank();
    }

    function testPredictPoolKeys() public view {
        // Test ERC4626 vault pair prediction
        PoolKey memory vaultPairKey =
            factory.predictERC4626VaultPoolKey(IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING);
        assertTrue(Currency.unwrap(vaultPairKey.currency0) != address(0));
        assertTrue(Currency.unwrap(vaultPairKey.currency1) != address(0));
        assertEq(vaultPairKey.fee, FEE);
        assertEq(vaultPairKey.tickSpacing, TICK_SPACING);

        // Test ERC4626 vault to token prediction
        PoolKey memory vaultToTokenKey =
            factory.predictERC4626VaultToTokenPoolKey(IERC4626(address(vaultA)), address(tokenA), FEE, TICK_SPACING);
        assertTrue(Currency.unwrap(vaultToTokenKey.currency0) != address(0));
        assertTrue(Currency.unwrap(vaultToTokenKey.currency1) != address(0));

        // Test Aave to ERC4626 prediction
        PoolKey memory aaveToVaultKey =
            factory.predictAaveToERC4626PoolKey(address(aTokenA), IERC4626(address(vaultA)), FEE, TICK_SPACING);
        assertTrue(Currency.unwrap(aaveToVaultKey.currency0) != address(0));
        assertTrue(Currency.unwrap(aaveToVaultKey.currency1) != address(0));

        // Test Aave to token prediction
        PoolKey memory aaveToTokenKey =
            factory.predictAaveToTokenPoolKey(address(aTokenA), address(tokenA), FEE, TICK_SPACING);
        assertTrue(Currency.unwrap(aaveToTokenKey.currency0) != address(0));
        assertTrue(Currency.unwrap(aaveToTokenKey.currency1) != address(0));

        // Test Aave pair prediction
        PoolKey memory aavePairKey = factory.predictAavePoolKey(address(aTokenA), address(aTokenB), FEE, TICK_SPACING);
        assertTrue(Currency.unwrap(aavePairKey.currency0) != address(0));
        assertTrue(Currency.unwrap(aavePairKey.currency1) != address(0));
    }

    function testPredictedPoolKeyMatchesActual() public {
        // Predict the pool key before deployment
        PoolKey memory predictedKey =
            factory.predictERC4626VaultPoolKey(IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING);

        // Deploy the actual pool
        (ERC4626VaultWrapper vaultWrapperA, ERC4626VaultWrapper vaultWrapperB) = factory.createERC4626VaultPool(
            IERC4626(address(vaultA)), IERC4626(address(vaultB)), FEE, TICK_SPACING, SQRT_PRICE_X96
        );

        // Build the actual pool key
        PoolKey memory actualKey = _buildPoolKey(address(vaultWrapperA), address(vaultWrapperB));

        // Verify they match
        assertEq(Currency.unwrap(predictedKey.currency0), Currency.unwrap(actualKey.currency0));
        assertEq(Currency.unwrap(predictedKey.currency1), Currency.unwrap(actualKey.currency1));
        assertEq(predictedKey.fee, actualKey.fee);
        assertEq(predictedKey.tickSpacing, actualKey.tickSpacing);
        assertEq(address(predictedKey.hooks), address(actualKey.hooks));
    }

    function _generateSalt(address token0, address token1, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(token0, token1, fee, tickSpacing));
    }

    function _generateImmutableArgsForVaultWrapper(address vault) internal view returns (bytes memory) {
        return abi.encodePacked(address(factory), address(yieldHarvestingHook), vault);
    }

    function _generateImmutableArgsForAaveWrapper(address aToken) internal view returns (bytes memory) {
        return abi.encodePacked(address(factory), address(yieldHarvestingHook), aToken);
    }

    function _buildPoolKey(address token0, address token1) internal view returns (PoolKey memory) {
        (address currency0, address currency1) = token0 < token1 ? (token0, token1) : (token1, token0);

        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(address(yieldHarvestingHook)))
        });
    }
}
