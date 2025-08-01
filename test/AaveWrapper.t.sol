// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {AaveWrapper} from "src/VaultWrappers/AaveWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/interfaces/IAToken.sol";

import {IPoolDataProvider} from "@aave-v3-core/interfaces/IPoolDataProvider.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

contract AaveWrapperTest is Test {
    address aaveWrapperImplementation;
    address yieldHarvestingHook = makeAddr("YieldHarvestingHook");
    AaveWrapper aaveWrapper;
    IPool aavePool;

    IPoolAddressesProvider addressProvider = IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e); // Aave V3 Provider

    function setUp() public {
        string memory fork_url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(fork_url, 22473612);

        aavePool = IPool(addressProvider.getPool());
        aaveWrapperImplementation = address(new AaveWrapper());
    }

    function _deployAaveWrapper(IAToken aToken) internal returns (AaveWrapper) {
        return AaveWrapper(
            LibClone.cloneDeterministic(
                aaveWrapperImplementation,
                abi.encodePacked(address(this), yieldHarvestingHook, address(aToken), address(aavePool)),
                keccak256(abi.encodePacked(address(aToken)))
            )
        );
    }

    function testMaxDepositWhenActive() public {
        IAToken aToken = IAToken(0x0B925eD163218f6662a35e0f0371Ac234f9E9371); // wstETH aToken

        aaveWrapper = _deployAaveWrapper(aToken);

        assertEq(
            aaveWrapper.maxDeposit(address(this)),
            424669147063254908399343,
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
