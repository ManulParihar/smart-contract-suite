pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ESIMWallet} from "./ESIMWallet.sol";
import {Registry} from "../Registry.sol";
import {UpgradeableBeacon} from "../UpgradableBeacon.sol";

error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();

/// @notice Contract for deploying a new eSIM wallet
contract ESIMWalletFactory is Initializable, OwnableUpgradeable {
    /// @notice Emitted when the eSIM wallet factory is deployed
    event ESIMWalletFactorydeployed(
        address indexed _upgradeManager,
        address indexed _eSIMWalletImplementation,
        address indexed beacon
    );

    /// @notice Emitted when a new eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress,
        address indexed _caller
    );

    /// @notice Address of the registry contract
    Registry public registry;

    /// @notice Implementation at the time of deployment
    address public eSIMWalletImplementation;

    /// @notice Beacon referenced by each deployment of a savETH vault
    address public beacon;

    /// @notice Set to true if eSIM wallet address is deployed using the factory, false otherwise
    mapping(address => bool) public isESIMWalletDeployed;

    modifier onlyRegistryOrDeviceWalletFactoryOrDeviceWallet() {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            !registry.isDeviceWalletValid(msg.sender)
        ) {
            revert OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();
        }
        _;
    }
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    {}

    /// @param _registryContractAddress Address of the registry contract
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize (address _registryContractAddress, address _upgradeManager) external initializer {
        require(_registryContractAddress != address(0), "Address cannot be zero");
        require(_upgradeManager != address(0), "Address cannot be zero");

        registry = Registry(_registryContractAddress);

        // eSIM wallet implementation (logic) contract during deployment
        eSIMWalletImplementation = address(new ESIMWallet());
        // Upgradable beacon for eSIM wallet implementation contract
        beacon = address(new UpgradeableBeacon(eSIMWalletImplementation, _upgradeManager));

        emit ESIMWalletFactorydeployed(
            _upgradeManager,
            eSIMWalletImplementation,
            beacon
        );

        _transferOwnership(_upgradeManager);
    }

    /// Function to deploy an eSIM wallet
    /// @dev can only be called by the respective deviceWallet contract
    /// @param _deviceWalletAddress Address of the associated device wallet
    /// @return Address of the newly deployed eSIM wallet
    function deployESIMWallet(
        address _deviceWalletAddress,
        uint256 _salt
    ) external onlyRegistryOrDeviceWalletFactoryOrDeviceWallet returns (address) {

        // msg.value will be sent along with the abi.encodeCall
        address eSIMWalletAddress = address(
            payable(
                new ERC1967Proxy{salt : bytes32(_salt)}(
                    address(eSIMWalletImplementation),
                    abi.encodeCall(
                        ESIMWallet.initialize, 
                        (address(this), _deviceWalletAddress)
                    )
                )
            )
        );
        isESIMWalletDeployed[eSIMWalletAddress] = true;

        emit ESIMWalletDeployed(eSIMWalletAddress, _deviceWalletAddress, msg.sender);

        return eSIMWalletAddress;
    }
}
