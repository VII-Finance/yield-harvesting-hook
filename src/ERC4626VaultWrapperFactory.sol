// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract ERC4626VaultWrapperFactory {
    IPoolManager public immutable poolManager;
    address public immutable harvester;

    event VaultWrapperCreated(address indexed vault, address indexed vaultWrapper);

    constructor(address _harvester) {
        harvester = _harvester;
    }

    function createVaultWrapper(ERC4626 vault) external returns (ERC4626VaultWrapper vaultWrapper) {
        bytes32 salt = keccak256(abi.encodePacked(address(vault)));

        vaultWrapper = new ERC4626VaultWrapper{salt: salt}(harvester);
        vaultWrapper.initialize(address(vault), getWrapperName(vault), getWrapperSymbol(vault));

        emit VaultWrapperCreated(address(vault), address(vaultWrapper));
    }

    function getWrapperName(ERC4626 vault) public view returns (string memory) {
        return string(abi.encodePacked("VII Finance Wrapped ", vault.name()));
    }

    function getWrapperSymbol(ERC4626 vault) public view returns (string memory) {
        return string(abi.encodePacked("VII-", vault.symbol()));
    }

    function _computeCreate2Address(bytes32 salt, bytes memory bytecode) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function getVaultWrapperBytecode() public view returns (bytes memory) {
        return abi.encodePacked(type(ERC4626VaultWrapper).creationCode, abi.encode(harvester));
    }

    function getVaultWrapperAddress(address vault) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(vault));
        bytes memory bytecode = getVaultWrapperBytecode();
        return _computeCreate2Address(salt, bytecode);
    }
}
