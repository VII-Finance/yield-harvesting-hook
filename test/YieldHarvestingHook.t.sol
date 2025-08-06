// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Fuzzers} from "lib/v4-periphery/lib/v4-core/src/test/Fuzzers.sol";
import {CustomRevert} from "lib/v4-periphery/lib/v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

import {YieldHarvestingHook} from "src/YieldHarvestingHook.sol";
import {ERC4626VaultWrapperFactory} from "src/ERC4626VaultWrapperFactory.sol";
import {ERC4626VaultWrapper} from "src/VaultWrappers/ERC4626VaultWrapper.sol";
import {BaseVaultWrapper} from "src/VaultWrappers/Base/BaseVaultWrapper.sol";
import {MockERC4626} from "test/utils/MockERC4626.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {FeeMath, PositionConfig} from "test/utils/libraries/FeeMath.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockAaveWrapper} from "test/utils/MockAaveWrapper.sol";

contract MockERC4626VaultWrapperFactory is ERC4626VaultWrapperFactory {
    constructor(address _owner, PoolManager _manager, address _yieldHarvestingHook)
        ERC4626VaultWrapperFactory(_owner, _manager, _yieldHarvestingHook)
    {
        aaveWrapperImplementation = address(new MockAaveWrapper());
    }
}

contract MockYieldHarvestingHook is YieldHarvestingHook {
    constructor(address _owner, PoolManager _manager) YieldHarvestingHook(_owner, _manager) {
        erc4626VaultWrapperFactory = address(new MockERC4626VaultWrapperFactory(_owner, _manager, address(this)));
    }
}

contract YieldHarvestingHookTest is Fuzzers, Test {
    using StateLibrary for PoolManager;

    address aavePool = makeAddr("AavePool");
    address factoryOwner = makeAddr("factoryOwner");
    PoolManager public poolManager;
    YieldHarvestingHook public yieldHarvestingHook;
    ERC4626VaultWrapperFactory public vaultWrappersFactory;

    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public swapRouter;

    MockERC4626 public underlyingVault0;
    MockERC4626 public underlyingVault1;
    MockERC20 public asset0;
    MockERC20 public asset1;
    BaseVaultWrapper public vaultWrapper0;
    BaseVaultWrapper public vaultWrapper1;

    // For mixed pool testing (vault + raw asset)
    MockERC20 public rawAsset;
    MockERC4626 public mixedVault;
    MockERC20 public mixedVaultAsset;
    BaseVaultWrapper public mixedVaultWrapper;
    PoolKey public mixedPoolKey;

    PoolKey public poolKey;

    address public poolManagerOwner = makeAddr("poolManagerOwner");

    uint160 constant HOOK_PERMISSIONS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

    bool isAaveWrapperTest;

    function setUp() public {
        poolManager = new PoolManager(poolManagerOwner);

        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);

        (, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_PERMISSIONS,
            type(MockYieldHarvestingHook).creationCode,
            abi.encode(factoryOwner, poolManager)
        );

        yieldHarvestingHook = new MockYieldHarvestingHook{salt: salt}(factoryOwner, poolManager);

        vaultWrappersFactory = ERC4626VaultWrapperFactory(yieldHarvestingHook.erc4626VaultWrapperFactory());
    }

    function setUpVaults(bool _isAaveWrapperTest) public {
        isAaveWrapperTest = _isAaveWrapperTest;

        MockERC20 assetA = new MockERC20();
        MockERC4626 underlyingVaultA = new MockERC4626(assetA);

        MockERC20 assetB = new MockERC20();
        MockERC4626 underlyingVaultB = new MockERC4626(assetB);

        BaseVaultWrapper vaultWrapperA;
        BaseVaultWrapper vaultWrapperB;

        if (isAaveWrapperTest) {
            (vaultWrapperA, vaultWrapperB) = vaultWrappersFactory.createAavePool(
                (address(underlyingVaultA)), (address(underlyingVaultB)), 3000, 60, Constants.SQRT_PRICE_1_1
            );
        } else {
            (vaultWrapperA, vaultWrapperB) = vaultWrappersFactory.createERC4626VaultPool(
                IERC4626(address(underlyingVaultA)),
                IERC4626(address(underlyingVaultB)),
                3000,
                60,
                Constants.SQRT_PRICE_1_1
            );
        }
        // Compare vaultWrapper addresses and assign 0/1 based on which is lower
        if (address(vaultWrapperA) < address(vaultWrapperB)) {
            asset0 = assetA;
            underlyingVault0 = underlyingVaultA;
            vaultWrapper0 = vaultWrapperA;

            asset1 = assetB;
            underlyingVault1 = underlyingVaultB;
            vaultWrapper1 = vaultWrapperB;
        } else {
            asset0 = assetB;
            underlyingVault0 = underlyingVaultB;
            vaultWrapper0 = vaultWrapperB;

            asset1 = assetA;
            underlyingVault1 = underlyingVaultA;
            vaultWrapper1 = vaultWrapperA;
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(address(vaultWrapper0)),
            currency1: Currency.wrap(address(vaultWrapper1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: yieldHarvestingHook
        });

        // Setup mixed pool (vault + raw asset)
        rawAsset = new MockERC20();
        mixedVaultAsset = new MockERC20();
        mixedVault = new MockERC4626(mixedVaultAsset);

        // Create pool with vault wrapper and raw asset using factory

        if (isAaveWrapperTest) {
            mixedVaultWrapper = vaultWrappersFactory.createAaveToTokenPool(
                address(mixedVault), address(rawAsset), 3000, 60, Constants.SQRT_PRICE_1_1
            );
        } else {
            mixedVaultWrapper = vaultWrappersFactory.createERC4626VaultToTokenPool(
                IERC4626(address(mixedVault)), address(rawAsset), 3000, 60, Constants.SQRT_PRICE_1_1
            );
        }

        // Determine currency order for mixed pool
        Currency vaultCurrency = Currency.wrap(address(mixedVaultWrapper));
        Currency rawCurrency = Currency.wrap(address(rawAsset));

        mixedPoolKey = PoolKey({
            currency0: address(mixedVaultWrapper) < address(rawAsset) ? vaultCurrency : rawCurrency,
            currency1: address(mixedVaultWrapper) < address(rawAsset) ? rawCurrency : vaultCurrency,
            fee: 3000,
            tickSpacing: 60,
            hooks: yieldHarvestingHook
        });
    }

    function modifyLiquidity(ModifyLiquidityParams memory params, uint160 sqrtPriceX96) internal {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        if (params.liquidityDelta != 0) {
            //why is above estimate incorrect?
            amount0 = amount0 * 2 + 2;
            amount1 = amount1 * 2 + 2;

            asset0.mint(address(this), amount0);
            asset1.mint(address(this), amount1);

            asset0.approve(address(underlyingVault0), amount0);
            asset1.approve(address(underlyingVault1), amount1);

            uint256 underlyingVaultShares0 = underlyingVault0.deposit(amount0, address(this));
            uint256 underlyingVaultShares1 = underlyingVault1.deposit(amount1, address(this));

            underlyingVault0.approve(address(vaultWrapper0), underlyingVaultShares0);
            underlyingVault1.approve(address(vaultWrapper1), underlyingVaultShares1);

            vaultWrapper0.deposit(underlyingVaultShares0, address(this));
            vaultWrapper1.deposit(underlyingVaultShares1, address(this));

            //approve this to the liquidity router
            vaultWrapper0.approve(address(modifyLiquidityRouter), type(uint256).max);
            vaultWrapper1.approve(address(modifyLiquidityRouter), type(uint256).max);
        }

        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");
    }

    function test_yieldAndHarvestBeforeSwap(
        ModifyLiquidityParams memory params,
        uint256 yield0,
        uint256 yield1,
        bool isAaveWrapper
    ) public {
        setUpVaults(isAaveWrapper);
        //liquidity to full range to make test simpler
        params.tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        params.tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        params.liquidityDelta = bound(params.liquidityDelta, 1, type(int120).max);

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());

        params = createFuzzyLiquidityParams(poolKey, params, sqrtRatioX96);

        modifyLiquidity(params, sqrtRatioX96);

        yield0 = bound(yield0, 1, 2 ** 100);
        yield1 = bound(yield1, 1, 2 ** 100);

        //we mint this tokens to the underlying vaults
        if (isAaveWrapperTest) {
            asset0.mint(address(this), yield0);
            asset1.mint(address(this), yield1);

            asset0.approve(address(underlyingVault0), yield0);
            asset1.approve(address(underlyingVault1), yield1);

            underlyingVault0.deposit(yield0, address(vaultWrapper0));
            underlyingVault1.deposit(yield1, address(vaultWrapper1));
        } else {
            asset0.mint(address(underlyingVault0), yield0);
            asset1.mint(address(underlyingVault1), yield1);
        }

        //make sure poolManager balance has increased
        uint256 poolManagerBalance0Before = poolKey.currency0.balanceOf(address(poolManager));
        uint256 poolManagerBalance1Before = poolKey.currency1.balanceOf(address(poolManager));

        // do a small swap so to make sure we harvest and donate
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1), // exact input, 0 for 1
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(params.tickLower) + 1
        });

        vaultWrapper0.approve(address(swapRouter), type(uint256).max);
        vaultWrapper1.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        //make sure balance has increase by yield0 and yield1
        assertApproxEqAbs(
            poolKey.currency0.balanceOf(address(poolManager)) - poolManagerBalance0Before,
            yield0,
            1,
            "PoolManager balance for currency0 should increase by yield0"
        );
        assertApproxEqAbs(
            poolKey.currency1.balanceOf(address(poolManager)) - poolManagerBalance1Before,
            yield1,
            1,
            "PoolManager balance for currency1 should increase by yield1"
        );

        PositionConfig memory config = PositionConfig({
            poolKey: poolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            salt: params.salt
        });

        BalanceDelta feesOwed = FeeMath.getFeesOwed(poolManager, config, address(modifyLiquidityRouter));

        //make sure feesOwed is equal to yield0 and yield1
        assertApproxEqAbs(feesOwed.amount0(), int256(yield0), 1, "feesOwed amount0 mismatch");
        assertApproxEqAbs(feesOwed.amount1(), int256(yield1), 1, "feesOwed amount1 mismatch");

        //increase liquidity by 0 and see the balance increase because the fees will be distributed
        uint256 balance0Before = poolKey.currency0.balanceOfSelf();
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();

        params.liquidityDelta = 0;
        modifyLiquidity(params, sqrtRatioX96);

        assertApproxEqAbs(
            poolKey.currency0.balanceOfSelf() - balance0Before,
            yield0,
            1,
            "Balance for currency0 should increase by yield0"
        );
        assertApproxEqAbs(
            poolKey.currency1.balanceOfSelf() - balance1Before,
            yield1,
            1,
            "Balance for currency1 should increase by yield1"
        );
    }

    function modifyMixedLiquidity(ModifyLiquidityParams memory params, uint160 sqrtPriceX96) internal {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        if (params.liquidityDelta != 0) {
            // Add buffer for estimation inaccuracy
            amount0 = amount0 * 2 + 2;
            amount1 = amount1 * 2 + 2;

            bool isVaultWrapper0 = Currency.unwrap(mixedPoolKey.currency0) == address(mixedVaultWrapper);

            if (isVaultWrapper0) {
                mixedVaultAsset.mint(address(this), amount0);
                mixedVaultAsset.approve(address(mixedVault), amount0);
                uint256 vaultShares = mixedVault.deposit(amount0, address(this));
                mixedVault.approve(address(mixedVaultWrapper), vaultShares);
                mixedVaultWrapper.deposit(vaultShares, address(this));

                rawAsset.mint(address(this), amount1);

                mixedVaultWrapper.approve(address(modifyLiquidityRouter), type(uint256).max);
                rawAsset.approve(address(modifyLiquidityRouter), type(uint256).max);
            } else {
                rawAsset.mint(address(this), amount0);

                mixedVaultAsset.mint(address(this), amount1);
                mixedVaultAsset.approve(address(mixedVault), amount1);
                uint256 vaultShares = mixedVault.deposit(amount1, address(this));
                mixedVault.approve(address(mixedVaultWrapper), vaultShares);
                mixedVaultWrapper.deposit(vaultShares, address(this));

                rawAsset.approve(address(modifyLiquidityRouter), type(uint256).max);
                mixedVaultWrapper.approve(address(modifyLiquidityRouter), type(uint256).max);
            }
        }

        modifyLiquidityRouter.modifyLiquidity(mixedPoolKey, params, "");
    }

    function test_mixedPoolYieldHarvesting(ModifyLiquidityParams memory params, uint256 vaultYield, bool isAaveWrapper)
        public
    {
        setUpVaults(isAaveWrapper);
        // Test yield harvesting in a mixed pool (one vault wrapper + one raw asset)
        // This verifies that only the vault wrapper currency generates yield while the raw asset doesn't

        // Liquidity to full range to make test simpler
        params.tickLower = TickMath.minUsableTick(mixedPoolKey.tickSpacing);
        params.tickUpper = TickMath.maxUsableTick(mixedPoolKey.tickSpacing);

        params.liquidityDelta = bound(params.liquidityDelta, 1, type(int120).max);

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(mixedPoolKey.toId());

        params = createFuzzyLiquidityParams(mixedPoolKey, params, sqrtRatioX96);

        modifyMixedLiquidity(params, sqrtRatioX96);

        vaultYield = bound(vaultYield, 1, 2 ** 100);

        // Generate yield by minting tokens to the underlying vault
        if (isAaveWrapperTest) {
            mixedVaultAsset.mint(address(this), vaultYield);
            mixedVaultAsset.approve(address(mixedVault), vaultYield);
            mixedVault.deposit(vaultYield, address(mixedVaultWrapper));
        } else {
            mixedVaultAsset.mint(address(mixedVault), vaultYield);
        }

        // Record initial balances
        uint256 poolManagerBalance0Before = mixedPoolKey.currency0.balanceOf(address(poolManager));
        uint256 poolManagerBalance1Before = mixedPoolKey.currency1.balanceOf(address(poolManager));

        // Determine which currency is the vault wrapper
        bool isVaultWrapper0 = Currency.unwrap(mixedPoolKey.currency0) == address(mixedVaultWrapper);

        // Do a small swap to trigger harvest
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(params.tickLower) + 1
        });

        mixedVaultWrapper.approve(address(swapRouter), type(uint256).max);
        rawAsset.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            mixedPoolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), ""
        );

        // Check that yield was harvested for the vault wrapper currency only
        if (isVaultWrapper0) {
            // Vault wrapper is currency0, should have yield
            assertApproxEqAbs(
                mixedPoolKey.currency0.balanceOf(address(poolManager)) - poolManagerBalance0Before,
                vaultYield,
                1,
                "PoolManager balance for vault wrapper currency should increase by yield"
            );
            assertApproxEqAbs(
                mixedPoolKey.currency1.balanceOf(address(poolManager)) - poolManagerBalance1Before,
                0,
                1,
                "PoolManager balance for raw asset currency should not change from yield"
            );
        } else {
            // Raw asset is currency0, should have minimal change (only from swap, not yield)
            assertApproxEqAbs(
                mixedPoolKey.currency0.balanceOf(address(poolManager)) - poolManagerBalance0Before,
                0,
                1,
                "PoolManager balance for raw asset currency should not change from yield"
            );
            // Vault wrapper is currency1, should have yield
            assertApproxEqAbs(
                mixedPoolKey.currency1.balanceOf(address(poolManager)) - poolManagerBalance1Before,
                vaultYield,
                1,
                "PoolManager balance for vault wrapper currency should increase by yield"
            );
        }

        // Verify fees are distributed correctly by modifying liquidity with 0 delta
        PositionConfig memory config = PositionConfig({
            poolKey: mixedPoolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            salt: params.salt
        });

        BalanceDelta feesOwed = FeeMath.getFeesOwed(poolManager, config, address(modifyLiquidityRouter));

        if (isVaultWrapper0) {
            assertApproxEqAbs(feesOwed.amount0(), int256(vaultYield), 1, "feesOwed amount0 should match vault yield");
            // Raw asset should have minimal fees (only from swap, not yield)
            int128 rawFees = feesOwed.amount1();
            uint256 absRawFees = rawFees >= 0 ? uint256(int256(rawFees)) : uint256(int256(-rawFees));
            assertLt(absRawFees, 10, "feesOwed amount1 should be minimal for raw asset");
        } else {
            // Raw asset should have minimal fees (only from swap, not yield)
            int128 rawFees = feesOwed.amount0();
            uint256 absRawFees = rawFees >= 0 ? uint256(int256(rawFees)) : uint256(int256(-rawFees));
            assertLt(absRawFees, 10, "feesOwed amount0 should be minimal for raw asset");
            assertApproxEqAbs(feesOwed.amount1(), int256(vaultYield), 1, "feesOwed amount1 should match vault yield");
        }
    }

    function testPoolInitializationFailsIfNotFactory(uint160 sqrtPriceX96, bool isAaveWrapper) public {
        setUpVaults(isAaveWrapper);

        PoolKey memory PoolKeyNotYetInitialised = PoolKey({
            currency0: Currency.wrap(address(vaultWrapper0)),
            currency1: Currency.wrap(address(vaultWrapper1)),
            fee: 500,
            tickSpacing: 10,
            hooks: yieldHarvestingHook
        });
        vm.expectRevert();
        poolManager.initialize(PoolKeyNotYetInitialised, sqrtPriceX96);
    }
}
