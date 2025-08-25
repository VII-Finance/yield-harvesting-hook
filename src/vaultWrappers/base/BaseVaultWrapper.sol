// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";

import {IVaultWrapper} from "src/interfaces/IVaultWrapper.sol";

abstract contract BaseVaultWrapper is ERC4626, IVaultWrapper {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_FEE_DIVISOR = 14; // Maximum fees 7.14%

    uint256 private constant ADDRESS_LENGTH = 20;
    uint256 private constant FACTORY_OFFSET = 0;
    uint256 private constant YIELD_HOOK_OFFSET = 1;
    uint256 private constant UNDERLYING_VAULT_OFFSET = 2;

    uint256 public feeDivisor;
    address public feeReceiver;

    error NotYieldHarvester();
    error InvalidFeeParams();
    error NotFactory();

    event FeeParametersSet(uint256 feeDivisor, address feeReceiver);

    constructor() ERC4626(IERC20(address(0))) ERC20("", "") {}

    function getFactory() public view returns (address) {
        return getImmutableArgAddress(FACTORY_OFFSET);
    }

    function getYieldHarvestingHook() public view returns (address) {
        return getImmutableArgAddress(YIELD_HOOK_OFFSET);
    }

    function getUnderlyingVault() public view returns (address) {
        return getImmutableArgAddress(UNDERLYING_VAULT_OFFSET);
    }

    function getImmutableArgAddress(uint256 argOffset) internal view returns (address) {
        uint256 start = argOffset * ADDRESS_LENGTH;
        uint256 end = start + ADDRESS_LENGTH;
        return address(bytes20(LibClone.argsOnClone(address(this), start, end)));
    }

    function _getMaxWithdrawableUnderlyingAssets() internal view virtual returns (uint256);

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return string(abi.encodePacked("VII Finance Wrapped ", ERC20(getUnderlyingVault()).name()));
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return string(abi.encodePacked("VII-", ERC20(getUnderlyingVault()).symbol()));
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(getUnderlyingVault()).decimals();
    }

    function asset() public view override returns (address) {
        return getUnderlyingVault();
    }

    function setFeeParameters(uint256 _feeDivisor, address _feeReceiver) external {
        if (_msgSender() != getFactory()) revert NotFactory();
        if (_feeDivisor != 0 && _feeDivisor < MIN_FEE_DIVISOR) revert InvalidFeeParams();
        if (_feeReceiver == address(0)) revert InvalidFeeParams();

        feeDivisor = _feeDivisor;
        feeReceiver = _feeReceiver;

        emit FeeParametersSet(_feeDivisor, _feeReceiver);
    }

    function pendingYield() public view returns (uint256, uint256) {
        uint256 totalYield = totalPendingYield();
        if (totalYield == 0) return (0, 0);

        uint256 fees = _calculateFees(totalYield);

        return (totalYield - fees, fees);
    }

    function totalPendingYield() public view returns (uint256) {
        uint256 maxWithdrawableUnderlyingAssets = _getMaxWithdrawableUnderlyingAssets();
        uint256 currentSupply = totalSupply();
        if (maxWithdrawableUnderlyingAssets > currentSupply) {
            return maxWithdrawableUnderlyingAssets - currentSupply;
        }
        return 0;
    }

    function _calculateFees(uint256 totalYield) internal view returns (uint256) {
        if (feeDivisor == 0) {
            return 0;
        }
        return totalYield / feeDivisor;
    }

    function harvest(address to) external returns (uint256 harvestedAssets, uint256 fees) {
        if (_msgSender() != getYieldHarvestingHook()) revert NotYieldHarvester();
        (harvestedAssets, fees) = pendingYield();
        if (fees > 0) {
            _mint(feeReceiver, fees);
        }
        if (harvestedAssets > 0) {
            _mint(to, harvestedAssets);
        }
    }

    // burn capabilities so that insurance fund can burn tokens to restore solvency if there is bad debt socialization in underlying vaults
    function burn(uint256 value) public {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }
}
