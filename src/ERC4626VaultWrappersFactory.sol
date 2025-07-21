// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ERC4626VaultWrapper} from "src/ERC4626VaultWrapper.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";

contract ERC4626VaultWrappersFactory {
    address public immutable harvester;
    mapping(address asset => uint256 count) public vaultWrappersCount;

    event VaultWrapperCreated(address indexed asset, address indexed vault, address indexed vaultWrapper);

    constructor(address _harvester) {
        harvester = _harvester;
    }

    function createVaultWrapper(ERC4626 vault) external returns (ERC4626VaultWrapper vaultWrapper) {
        ERC20 asset = vault.asset();
        bytes32 salt = keccak256(abi.encodePacked(address(vault), vaultWrappersCount[address(vault)]));

        // TODO: make sure naming is something that makes sense and is numbered correctly
        vaultWrapper = new ERC4626VaultWrapper{salt: salt}(vault, harvester, asset.name(), asset.symbol());
        vaultWrappersCount[address(vault)]++;

        emit VaultWrapperCreated(address(asset), address(vault), address(vaultWrapper));
    }

    function _computeCreate2Address(bytes32 salt, bytes memory bytecode) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function getVaultWrapperBytecode(address vault) public view returns (bytes memory) {
        ERC20 asset = ERC4626(vault).asset();
        return abi.encodePacked(
            type(ERC4626VaultWrapper).creationCode, abi.encode(vault, harvester, asset.name(), asset.symbol())
        );
    }

    function getVaultWrapperAddress(address vault, uint256 vaultCount) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(vault, vaultCount));
        bytes memory bytecode = getVaultWrapperBytecode(vault);
        return _computeCreate2Address(salt, bytecode);
    }
}
