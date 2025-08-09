// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {AaveWrapper} from "src/VaultWrappers/AaveWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/interfaces/IAToken.sol";

import {IPoolDataProvider} from "@aave-v3-core/interfaces/IPoolDataProvider.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

contract AaveWrapperTest is Test {
    address aaveWrapperImplementation;
    address yieldHarvestingHook = makeAddr("YieldHarvestingHook");
    AaveWrapper aaveWrapper;
    IPool aavePool;

    IPoolAddressesProvider addressProvider = IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e); // Aave V3 Provider
    IPoolDataProvider dataProvider;

    function setUp() public {
        string memory fork_url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(fork_url, 22473612);

        aavePool = IPool(addressProvider.getPool());
        aaveWrapperImplementation = address(new AaveWrapper());
        dataProvider = IPoolDataProvider(addressProvider.getPoolDataProvider());
    }

    function _deployAaveWrapper(IAToken aToken) internal returns (AaveWrapper) {
        return AaveWrapper(
            LibClone.cloneDeterministic(
                aaveWrapperImplementation,
                abi.encodePacked(address(this), yieldHarvestingHook, address(aToken)),
                keccak256(abi.encodePacked(address(aToken)))
            )
        );
    }

    function _getSupplyCapAndCurrentSupply(IAToken aToken)
        internal
        view
        returns (uint256 supplyCapWithDecimals, uint256 currentSupply)
    {
        (, uint256 supplyCap) = dataProvider.getReserveCaps(aToken.UNDERLYING_ASSET_ADDRESS());
        supplyCapWithDecimals = supplyCap * (10 ** ERC20(address(aToken)).decimals());

        (, uint256 accruedToTreasuryScaled,,,,,,,, uint256 liquidityIndex,,) =
            dataProvider.getReserveData(aToken.UNDERLYING_ASSET_ADDRESS());

        currentSupply = WadRayMath.rayMul((aToken.scaledTotalSupply() + accruedToTreasuryScaled), liquidityIndex);
    }

    function testMaxDepositWhenActive() public {
        IAToken aToken = IAToken(0x0B925eD163218f6662a35e0f0371Ac234f9E9371); // wstETH aToken

        aaveWrapper = _deployAaveWrapper(aToken);

        (uint256 supplyCapWithDecimals, uint256 currentSupply) = _getSupplyCapAndCurrentSupply(aToken);

        assertEq(
            aaveWrapper.maxDeposit(address(this)),
            supplyCapWithDecimals - currentSupply,
            "Max deposit should equal supply cap - total supplied when active"
        );
    }

    function testMaxDepositWhenActiveNon18Decimals() public {
        IAToken aToken = IAToken(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a); // USDT aToken

        aaveWrapper = _deployAaveWrapper(aToken);

        (uint256 supplyCapWithDecimals, uint256 currentSupply) = _getSupplyCapAndCurrentSupply(aToken);

        assertEq(
            aaveWrapper.maxDeposit(address(this)),
            supplyCapWithDecimals - currentSupply,
            "Max deposit should equal supply cap - total supplied when active"
        );
    }

    function testMaxDepositWhenInactive() public {
        IAToken aToken = IAToken(0x82F9c5ad306BBa1AD0De49bB5FA6F01bf61085ef); // FXS aToken (this token is frozen at the fork block)
        aaveWrapper = _deployAaveWrapper(aToken);
        assertEq(aaveWrapper.maxDeposit(address(this)), 0, "Max deposit should equal 0 when aToken is inactive");
    }

    function testMaxWithdraw() public {
        IAToken aToken = IAToken(0x0B925eD163218f6662a35e0f0371Ac234f9E9371); // wstETH aToken

        aaveWrapper = _deployAaveWrapper(aToken);

        deal(address(aaveWrapper), address(this), 1e19);
        assertEq(aaveWrapper.maxWithdraw(address(this)), 1e19);

        //if the balance is greater than available in aave, it should return the available amount
        deal(
            address(aaveWrapper),
            address(this),
            ERC20(IAToken(aaveWrapper.getUnderlyingVault()).UNDERLYING_ASSET_ADDRESS()).balanceOf(address(aToken)) + 1
        );
        assertEq(
            aaveWrapper.maxWithdraw(address(this)),
            ERC20(IAToken(aaveWrapper.getUnderlyingVault()).UNDERLYING_ASSET_ADDRESS()).balanceOf(address(aToken))
        );
    }
}
