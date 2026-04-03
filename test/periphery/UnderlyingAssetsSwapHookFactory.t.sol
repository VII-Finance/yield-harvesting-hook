// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {UnderlyingAssetsSwapHook} from "src/periphery/UnderlyingAssetsSwapHook/UnderlyingAssetsSwapHook.sol";
import {UnderlyingAssetsSwapHookFactory} from "src/periphery/UnderlyingAssetsSwapHook/UnderlyingAssetsSwapHookFactory.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";

contract UnderlyingAssetsSwapHookFactoryTest is Test {
    using StateLibrary for PoolManager;
    using PoolIdLibrary for PoolKey;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 constant YIELD_HOOK_PERMISSIONS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

    uint24 constant FEE = 18;
    int24 constant TICK_SPACING = 1;

    PoolManager poolManager;
    YieldHarvestingHook yieldHarvestingHook;
    UnderlyingAssetsSwapHookFactory factory;

    MockERC20 rawAssetA;
    MockERC20 rawAssetB;
    MockERC4626 underlyingVaultA;
    MockERC4626 underlyingVaultB;
    MockERC4626 vaultWrapperA;
    MockERC4626 vaultWrapperB;

    PoolKey vaultWrapperPoolKey;

    function setUp() public {
        // Etch a no-op stub at the PERMIT2 address so the hook constructor's
        // IAllowanceTransfer.approve calls succeed without reverting.
        vm.etch(PERMIT2, hex"00"); // STOP opcode — accepts all calls, returns nothing

        poolManager = new PoolManager(address(this));

        (, bytes32 hookSalt) = HookMiner.find(
            address(this),
            YIELD_HOOK_PERMISSIONS,
            type(YieldHarvestingHook).creationCode,
            abi.encode(address(this), poolManager)
        );
        yieldHarvestingHook = new YieldHarvestingHook{salt: hookSalt}(address(this), poolManager);

        factory = new UnderlyingAssetsSwapHookFactory(poolManager);

        // Three-level vault hierarchy:
        //   rawAssetA (MockERC20) -> underlyingVaultA (MockERC4626) -> vaultWrapperA (MockERC4626)
        //   rawAssetB (MockERC20) -> underlyingVaultB (MockERC4626) -> vaultWrapperB (MockERC4626)
        rawAssetA = new MockERC20();
        rawAssetB = new MockERC20();
        underlyingVaultA = new MockERC4626(rawAssetA);
        underlyingVaultB = new MockERC4626(rawAssetB);
        // Cast the MockERC4626 to MockERC20 for the wrapper constructor (safe address cast)
        vaultWrapperA = new MockERC4626(MockERC20(address(underlyingVaultA)));
        vaultWrapperB = new MockERC4626(MockERC20(address(underlyingVaultB)));

        // Uniswap v4 requires currency0 < currency1
        (address vw0, address vw1) = address(vaultWrapperA) < address(vaultWrapperB)
            ? (address(vaultWrapperA), address(vaultWrapperB))
            : (address(vaultWrapperB), address(vaultWrapperA));

        vaultWrapperPoolKey = PoolKey({
            currency0: Currency.wrap(vw0),
            currency1: Currency.wrap(vw1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(yieldHarvestingHook))
        });
    }

    // ── Helper ────────────────────────────────────────────────────────────────

    function _createHook() internal returns (UnderlyingAssetsSwapHook hook, PoolKey memory assetPoolKey) {
        (, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);
        (hook, assetPoolKey) = factory.create(vaultWrapperPoolKey, salt);
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_setsPoolManager() public view {
        assertEq(address(factory.poolManager()), address(poolManager));
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    function test_requiredFlags_encodesExpectedPermissions() public view {
        uint160 expected = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
            | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(factory.REQUIRED_FLAGS(), expected);
    }

    function test_sqrtPrice1_1_constant() public view {
        assertEq(factory.SQRT_PRICE_1_1(), 79228162514264337593543950336);
    }

    // ── create() ──────────────────────────────────────────────────────────────

    function test_create_deploysHookAndInitializesPool() public {
        (, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);
        (UnderlyingAssetsSwapHook hook, PoolKey memory assetPoolKey) = factory.create(vaultWrapperPoolKey, salt);

        assertTrue(address(hook) != address(0), "Hook should be deployed");

        // Asset pool should be initialized in the PoolManager
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(assetPoolKey.toId());
        assertEq(sqrtPriceX96, factory.SQRT_PRICE_1_1(), "Pool should be initialized at 1:1 price");
    }

    function test_create_hookAddressSatisfiesRequiredFlags() public {
        (UnderlyingAssetsSwapHook hook,) = _createHook();
        uint160 flags = uint160(address(hook)) & factory.REQUIRED_FLAGS();
        assertEq(flags, factory.REQUIRED_FLAGS(), "Hook address must have all required flag bits set");
    }

    function test_create_setsHookForPool() public {
        (UnderlyingAssetsSwapHook hook,) = _createHook();
        PoolId poolId = vaultWrapperPoolKey.toId();
        assertEq(address(factory.hookForPool(poolId)), address(hook), "hookForPool should be set");
    }

    function test_create_emitsEvent() public {
        (, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);
        PoolId poolId = vaultWrapperPoolKey.toId();

        vm.expectEmit(true, false, false, false);
        emit UnderlyingAssetsSwapHookFactory.UnderlyingAssetsSwapHookCreated(PoolId.unwrap(poolId), address(0));

        factory.create(vaultWrapperPoolKey, salt);
    }

    function test_create_hookImmutables() public {
        (UnderlyingAssetsSwapHook hook,) = _createHook();

        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.factory(), address(factory));
        assertEq(address(hook.yieldHarvestingHook()), address(yieldHarvestingHook));
        assertEq(hook.fee(), FEE);
        assertEq(hook.tickSpacing(), TICK_SPACING);

        // vaultWrapper0 = currency0 of pool key (address-sorted lower)
        assertEq(address(hook.vaultWrapper0()), Currency.unwrap(vaultWrapperPoolKey.currency0));
        assertEq(address(hook.vaultWrapper1()), Currency.unwrap(vaultWrapperPoolKey.currency1));
    }

    function test_create_hookDerivesUnderlyingVaultsAndAssets() public {
        (UnderlyingAssetsSwapHook hook,) = _createHook();

        MockERC4626 vw0 = MockERC4626(Currency.unwrap(vaultWrapperPoolKey.currency0));
        MockERC4626 vw1 = MockERC4626(Currency.unwrap(vaultWrapperPoolKey.currency1));

        assertEq(address(hook.underlyingVault0()), address(vw0.asset()), "underlyingVault0 should be vaultWrapper0.asset()");
        assertEq(address(hook.underlyingVault1()), address(vw1.asset()), "underlyingVault1 should be vaultWrapper1.asset()");

        MockERC4626 uv0 = MockERC4626(address(vw0.asset()));
        MockERC4626 uv1 = MockERC4626(address(vw1.asset()));

        assertEq(address(hook.asset0()), address(uv0.asset()), "asset0 should be underlyingVault0.asset()");
        assertEq(address(hook.asset1()), address(uv1.asset()), "asset1 should be underlyingVault1.asset()");
    }

    function test_create_revertsIfHookAlreadyExists() public {
        _createHook();
        (, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);

        vm.expectRevert(
            abi.encodeWithSelector(
                UnderlyingAssetsSwapHookFactory.HookAlreadyExists.selector,
                address(factory.hookForPool(vaultWrapperPoolKey.toId()))
            )
        );
        factory.create(vaultWrapperPoolKey, salt);
    }

    function test_create_revertsIfInvalidSalt() public {
        // bytes32(0) almost certainly produces an address without REQUIRED_FLAGS set,
        // which causes BaseHook to revert during construction validation.
        vm.expectRevert();
        factory.create(vaultWrapperPoolKey, bytes32(0));
    }

    // ── findSalt() ────────────────────────────────────────────────────────────

    function test_findSalt_returnsAddressSatisfyingRequiredFlags() public view {
        (address hookAddress, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);

        assertTrue(salt != bytes32(0), "Salt should not be zero");
        assertTrue(
            uint160(hookAddress) & factory.REQUIRED_FLAGS() == factory.REQUIRED_FLAGS(),
            "Found address must have all required flags"
        );
    }

    function test_findSalt_matchesPredictedAddress() public view {
        (address hookAddress, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);
        address predicted = factory.predict(vaultWrapperPoolKey, salt);
        assertEq(predicted, hookAddress, "findSalt address should match predict");
    }

    // ── predict() ─────────────────────────────────────────────────────────────

    function test_predict_matchesDeployedAddress() public {
        (, bytes32 salt) = factory.findSalt(vaultWrapperPoolKey);
        address predicted = factory.predict(vaultWrapperPoolKey, salt);

        (UnderlyingAssetsSwapHook hook,) = factory.create(vaultWrapperPoolKey, salt);
        assertEq(address(hook), predicted, "Predicted address should match deployed hook");
    }

    // ── assetPoolKeyForPool() ─────────────────────────────────────────────────

    function test_assetPoolKeyForPool_hasSortedCurrencies() public {
        (UnderlyingAssetsSwapHook hook, PoolKey memory assetPoolKey) = _createHook();

        assertTrue(
            Currency.unwrap(assetPoolKey.currency0) < Currency.unwrap(assetPoolKey.currency1),
            "Asset pool must have sorted currencies"
        );

        // The currencies must be the raw assets of the underlying vaults
        address a0 = address(hook.asset0());
        address a1 = address(hook.asset1());
        (address expectedC0, address expectedC1) = a0 < a1 ? (a0, a1) : (a1, a0);

        assertEq(Currency.unwrap(assetPoolKey.currency0), expectedC0);
        assertEq(Currency.unwrap(assetPoolKey.currency1), expectedC1);
    }

    function test_assetPoolKeyForPool_feeAndTickSpacingMatch() public {
        (, PoolKey memory assetPoolKey) = _createHook();

        assertEq(assetPoolKey.fee, FEE);
        assertEq(assetPoolKey.tickSpacing, TICK_SPACING);
    }

    function test_assetPoolKeyForPool_hooksIsDeployedHook() public {
        (UnderlyingAssetsSwapHook hook, PoolKey memory assetPoolKey) = _createHook();

        assertEq(address(assetPoolKey.hooks), address(hook));
    }

    function test_assetPoolKeyForPool_overloads_returnSameResult() public {
        _createHook();

        PoolId poolId = vaultWrapperPoolKey.toId();
        PoolKey memory byId = factory.assetPoolKeyForPool(poolId);
        PoolKey memory byKey = factory.assetPoolKeyForPool(vaultWrapperPoolKey);

        assertEq(Currency.unwrap(byId.currency0), Currency.unwrap(byKey.currency0));
        assertEq(Currency.unwrap(byId.currency1), Currency.unwrap(byKey.currency1));
        assertEq(byId.fee, byKey.fee);
        assertEq(byId.tickSpacing, byKey.tickSpacing);
        assertEq(address(byId.hooks), address(byKey.hooks));
    }
}
