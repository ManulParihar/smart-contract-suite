pragma solidity 0.8.25;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {RegistryHelper} from "./RegistryHelper.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {P256Verifier} from "./P256Verifier.sol";
import {Errors} from "./Errors.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract Registry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RegistryHelper {

    /// @notice Entry point contract address (one entryPoint per chain)
    IEntryPoint public entryPoint;

    ///@notice eSIM wallet project admin address
    address public eSIMWalletAdmin;

    /// @notice Address of the vault that receives payments for the eSIM data bundles
    address public vault;

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    modifier onlyDeviceWallet() {
        if(isDeviceWalletValid[msg.sender] != true) revert Errors.OnlyDeviceWallet();
        _;
    }

    modifier onlyDeviceWalletFactory() {
        if(msg.sender != address(deviceWalletFactory)) revert Errors.OnlyDeviceWalletFactory();
        _;
    }

    // /// @custom:oz-upgrades-unsafe-allow constructor
    // constructor() initializer {}

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize(
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager,
        address _deviceWalletFactory,
        address _eSIMWalletFactory,
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) external initializer {
        require(_eSIMWalletAdmin != address(0), "_eSIMWalletAdmin 0");
        require(_vault != address(0), "_vault 0");
        require(_upgradeManager != address(0), "_upgradeManager 0");
        require(address(_entryPoint) != address(0), "_entryPoint 0");

        entryPoint = _entryPoint;
        eSIMWalletAdmin = _eSIMWalletAdmin;
        vault = _vault;
        upgradeManager = _upgradeManager;

        deviceWalletFactory = DeviceWalletFactory(_deviceWalletFactory);
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactory);

        __Ownable2Step_init();
        __Ownable_init(_upgradeManager);

        emit RegistryInitialized(
            _eSIMWalletAdmin, 
            _vault, 
            _upgradeManager, 
            address(deviceWalletFactory), 
            address(eSIMWalletFactory),
            address(_verifier)
        );
    }

    /// @notice Function to add or update the lazy wallet registry address
    function addOrUpdateLazyWalletRegistryAddress(
        address _lazyWalletRegistry
    ) public onlyOwner returns (address) {
        require(_lazyWalletRegistry != address(0), "_lazyWalletRegistry 0");

        lazyWalletRegistry = _lazyWalletRegistry;

        emit UpdatedLazyWalletRegistryAddress(_lazyWalletRegistry);

        return lazyWalletRegistry;
    }

    function updateDeviceWalletAssociatedWithESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) external onlyDeviceWallet {
        require(
            ESIMWallet(payable(_eSIMWalletAddress)).owner() == msg.sender ||
            isESIMWalletValid[_eSIMWalletAddress] == msg.sender,
            "Unauthorise caller or already assigned"
        );
        // address(0) => owner removed eSIM wallet from device wallet
        // msg.sender => new device wallet added the eSIM wallet
        // any other address => Unauthorised: user is trying to change owner without initiating transfer of ownership
        require(
            _deviceWalletAddress == address(0) || _deviceWalletAddress == msg.sender,
            "Transfer ownership first"
        );
        // Owner cannot change device wallet address in the middle of ownership transfer
        require(
            ESIMWallet(payable(_eSIMWalletAddress)).newRequestedOwner() == address(0),
            "Unauthorised action"
        );

        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
        emit UpdatedDeviceWalletassociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);
    }

    /// @dev For all the device wallets deployed by the esim wallet admin using the device wallet factory,
    ///      update the mappings
    /// @param _deviceWallet Address of the device wallet
    /// @param _deviceUniqueIdentifier String unique identifier associated with the device wallet
    function updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) external onlyDeviceWalletFactory {
        _updateDeviceWalletInfo(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    /// @notice Update eSIM standby status when being moved from one device wallet to another
    /// @param _eSIMWalletAddress Address of the eSIM wallet
    /// @param _isOnStandby Set to true when no device wallet is associated, false otherwise
    function toggleESIMWalletStandbyStatus(
        address _eSIMWalletAddress,
        bool _isOnStandby
    ) public onlyDeviceWallet {
        require(isESIMWalletValid[_eSIMWalletAddress] == msg.sender, "Unauthorised caller");

        isESIMWalletOnStandby[_eSIMWalletAddress] = _isOnStandby;
        emit ESIMWalletSetOnStandby(_eSIMWalletAddress, _isOnStandby, msg.sender);
    }
}
