pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import "./CustomStructs.sol";

error OnlyLazyWalletRegistry();

contract RegistryHelper {

    event WalletDeployed(
        string _deviceUniqueIdentifier,
        address indexed _deviceWallet,
        address indexed _eSIMWallet
    );

    event DeviceWalletInfoUpdated(
        address indexed _deviceWallet,
        string _deviceUniqueIdentifier,
        bytes32[2] _deviceWalletOwnerKey
    );

    event UpdatedDeviceWalletassociatedWithESIMWallet(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress
    );

    event UpdatedLazyWalletRegistryAddress(
        address indexed _lazyWalletRegistry
    );

    /// @notice Address of the Lazy wallet registry
    address public lazyWalletRegistry;

    /// @notice Device wallet factory instance
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice eSIM wallet factory instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice device unique identifier <> device wallet address
    ///         Mapping for all the device wallets deployed by the registry
    /// @dev Use this to check if a device identifier has already been used or not
    mapping(string => address) public uniqueIdentifierToDeviceWallet;

    /// @notice device wallet address <> owner P256 public key.
    mapping(address => bytes32[2]) public deviceWalletToOwner;

    /// @notice device wallet address <> boolean (true if deployed by the registry or device wallet factory)
    ///         Mapping of all the device wallets deployed by the registry (or the device wallet factory)
    ///         to their respective owner.
    mapping(address => bool) public isDeviceWalletValid;

    /// @notice eSIM wallet address <> device wallet address
    ///         All the eSIM wallets deployed using this registry are valid and set to true
    mapping(address => address) public isESIMWalletValid;

    modifier onlyLazyWalletRegistry() {
        if(msg.sender != lazyWalletRegistry) revert OnlyLazyWalletRegistry();
        _;
    }

    /// @notice Allow LazyWalletRegistry to deploy a device wallet and an eSIM wallet on behalf of a user
    /// @param _deviceWalletOwnerKey P256 public key of user
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and list of addresses of all the eSIM wallets
    function deployLazyWallet(
        bytes32[2] memory _deviceWalletOwnerKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        string[] memory _eSIMUniqueIdentifiers,
        DataBundleDetails[][] memory _dataBundleDetails
    ) external onlyLazyWalletRegistry returns (address, address[] memory) {
        require(
            uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] == address(0),
            "Device wallet already exists"
        );

        address deviceWallet = deviceWalletFactory.deployDeviceWallet(_deviceUniqueIdentifier, _deviceWalletOwnerKey, _salt);
        _updateDeviceWalletInfo(deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);

        address[] memory eSIMWallets;

        for(uint256 i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
            // increase salt for subsequent eSIM wallet deployments
            address eSIMWallet = eSIMWalletFactory.deployESIMWallet(deviceWallet, (_salt + i));
            emit WalletDeployed(_deviceUniqueIdentifier, deviceWallet, eSIMWallet);
            _updateESIMInfo(eSIMWallet, deviceWallet);

            // Since the eSIM unique identifier is already known in this scenario
            // We can execute the setESIMUniqueIdentifierForAnESIMWallet function in same transaction as deploying the smart wallet
            DeviceWallet(payable(deviceWallet)).setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, _eSIMUniqueIdentifiers[i]);

            // Populate data bundle purchase details for the eSIM wallet
            ESIMWallet(payable(eSIMWallet)).populateHistory(_dataBundleDetails[i]);

            eSIMWallets[i] = eSIMWallet;
        }

        return (deviceWallet, eSIMWallets);
    }

    function _updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) internal {
        uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] = _deviceWallet;
        isDeviceWalletValid[_deviceWallet] = true;
        deviceWalletToOwner[_deviceWallet] = _deviceWalletOwnerKey;

        emit DeviceWalletInfoUpdated(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    function _updateESIMInfo(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) internal {
        DeviceWallet(payable(_deviceWalletAddress)).updateESIMInfo(_eSIMWalletAddress, true, true);
        DeviceWallet(payable(_deviceWalletAddress)).updateDeviceWalletAssociatedWithESIMWallet(
            _eSIMWalletAddress,
            _deviceWalletAddress
        );

        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
    }
}
