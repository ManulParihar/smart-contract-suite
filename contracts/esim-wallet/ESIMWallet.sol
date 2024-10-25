// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IOwnableESIMWallet} from "../interfaces/IOwnableESIMWallet.sol";
import {DeviceWallet} from "../device-wallet/DeviceWallet.sol";
import {Registry} from "../Registry.sol";
import "../CustomStructs.sol";

error OnlyDeviceWallet();
error OnlyRegistry();
error FailedToTransfer();
error OnlyESIMWalletAdminOrESIMWalletfactoryOrDeviceWallet();

contract ESIMWallet is IOwnableESIMWallet, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Address for address;

    /// Emitted when the eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress,
        address indexed _owner
    );

    /// Emitted when the payment for a data bundle is made
    event DataBundleBought(
        string _dataBundleID,
        uint256 _dataBundlePrice,
        uint256 _ethFromUser
    );

    /// @notice Emitted when the eSIM unique identifier is initialised
    event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier);

    /// @notice Emitted when the lazy wallet registry populates history after wallet deployment
    event TransactionHistoryPopulated(DataBundleDetails[] _dataBundleDetails);

    /// @notice Emitted when ETH moves out of this contract
    event ETHSent(address indexed _recipient, uint256 _amount);

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @notice Device wallet contract instance associated with this eSIM wallet
    DeviceWallet public deviceWallet;

    /// @notice Array of all the data bundle purchase
    DataBundleDetails[] public transactionHistory;

    /// @dev A map from owner and spender to transfer approval. Determines whether
    ///      the spender can transfer this wallet from the owner.
    mapping(address => mapping(address => bool)) internal _isTransferApproved;

    modifier onlyDeviceWallet() {
        if (msg.sender != address(deviceWallet)) revert OnlyDeviceWallet();
        _;
    }

    modifier onlyRegistry() {
        if(msg.sender != address(deviceWallet.registry())) revert OnlyRegistry();
        _;
    }

    function _onlyESIMWalletAdminOrESIMWalletfactoryOrDeviceWallet() private view {
        if (
            msg.sender != eSIMWalletFactory &&
            msg.sender != deviceWallet.registry().eSIMWalletAdmin() &&
            msg.sender != address(deviceWallet)
        ) {
            revert OnlyESIMWalletAdminOrESIMWalletfactoryOrDeviceWallet();
        }
    }

    modifier onlyESIMWalletAdminOrESIMWalletfactoryOrDeviceWallet() {
        _onlyESIMWalletAdminOrESIMWalletfactoryOrDeviceWallet();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice ESIMWallet initialize function to initialise the contract
    /// @dev If _eSIMUniqueIdentifier is empty, the eSIM wallet is being deployed before buying an eSIM
    ///      If _eSIMUniqueIdentifier is non-empty, the eSIM wallet is being deployed after the eSIM has been bought by the user
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory contract address
    /// @param _deviceWalletAddress Device wallet contract address (the contract that deploys this eSIM wallet)
    function initialize(
        address _eSIMWalletFactoryAddress,
        address _deviceWalletAddress
    ) external initializer {
        require(_eSIMWalletFactoryAddress != address(0), "_eSIMWalletFactoryAddress 0");
        require(_deviceWalletAddress != address(0), "_deviceWalletAddress 0");

        eSIMWalletFactory = _eSIMWalletFactoryAddress;
        deviceWallet = DeviceWallet(payable(_deviceWalletAddress));

        __Ownable_init(_deviceWalletAddress);
        __ReentrancyGuard_init();

        emit ESIMWalletDeployed(address(this), _deviceWalletAddress, _deviceWalletAddress);
    }

    /// @notice Since buying the eSIM (along with data bundle) happens before the identifier is generated,
    ///         the identifier is to be set separately after the wallet is deployed and eSIM is created
    /// @dev This function can only be called once
    /// @param _eSIMUniqueIdentifier String that uniquely identifies eSIM wallet
    function setESIMUniqueIdentifier(string calldata _eSIMUniqueIdentifier) external onlyDeviceWallet {
        require(bytes(eSIMUniqueIdentifier).length == 0, "Already initialised");
        require(bytes(_eSIMUniqueIdentifier).length != 0, "_eSIMUniqueIdentifier 0");

        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;

        emit ESIMUniqueIdentifierInitialised(_eSIMUniqueIdentifier);
    }

    /// @notice Function to make payment for the data bundle
    /// @param _dataBundleDetail Details of the data bundle being bought. (dataBundleID, dataBundlePrice)
    /// @return True if the transaction is successful
    function buyDataBundle(DataBundleDetails memory _dataBundleDetail) public payable nonReentrant returns (bool) {
        require(bytes(_dataBundleDetail.dataBundleID).length > 0, "Data bundle ID cannot be empty");
        require(_dataBundleDetail.dataBundlePrice > 0, "Price cannot be zero");

        // 1. msg.value is received by contract
        // 2. if wallet balance is less than dataBundlePrice, pull ETH from device wallet
        // 3. send dataBundlePrice amount of ETH to vault
        uint256 walletBalance = address(this).balance;

        if (walletBalance < _dataBundleDetail.dataBundlePrice) {
            uint256 remainingETH = _dataBundleDetail.dataBundlePrice - walletBalance;
            deviceWallet.pullETH(remainingETH);
        }

        address vault = deviceWallet.getVaultAddress();
        _transferETH(vault, _dataBundleDetail.dataBundlePrice);

        transactionHistory.push(_dataBundleDetail);

        emit DataBundleBought(_dataBundleDetail.dataBundleID, _dataBundleDetail.dataBundlePrice, msg.value);

        return true;
    }

    /// @notice Function to populate history for lazy wallets. Can only be called once, by lazy wallet registry
    /// @param _dataBundleDetails Array of all the data bundle purchase details before the wallet was deployed
    function populateHistory(DataBundleDetails[] memory _dataBundleDetails) external onlyRegistry returns (bool) {
        require(transactionHistory.length == 0, "Wallet already in use");

        // Using transactionHistory = _dataBundleDetails; would be gas efficient
        // but it is not yet supported for struct types, hence using the loop
        for (uint256 i = 0; i < _dataBundleDetails.length; i++) {
            // Create a temporary variable in storage
            transactionHistory.push(); // Increase the length of transactionHistory by 1
            DataBundleDetails storage newTransaction = transactionHistory[transactionHistory.length - 1];
            newTransaction.dataBundleID = _dataBundleDetails[i].dataBundleID;
            newTransaction.dataBundlePrice = _dataBundleDetails[i].dataBundlePrice;
        }

        emit TransactionHistoryPopulated(_dataBundleDetails);

        return true;
    }

    /// @dev Returns the current owner of the wallet
    function owner() public view override(IOwnableESIMWallet, OwnableUpgradeable) returns (address) {
        return OwnableUpgradeable.owner();
    }

    /// @dev Transfers ownership from the current owner to another address
    /// @param newOwner The address that will be the new owner
    function transferOwnership(address newOwner) public override(IOwnableESIMWallet, OwnableUpgradeable) {
        // Only the admin of deviceWalletFactory contract can transfer ownership
        require(isTransferApproved(owner(), msg.sender), "Transfer not allowed");

        // Approval is revoked, in order to avoid unintended transfer allowance
        // if this wallet ever returns to the previous owner
        if (msg.sender != owner()) {
            _setApproval(owner(), msg.sender, false);
        }
        _transferOwnership(newOwner);
    }

    /// @dev Returns whether the address 'to' can transfer a wallet from address 'from'
    /// @param from The owner address
    /// @param to The spender address
    /// @notice The owner can always transfer the wallet to someone, i.e.,
    ///         approval from an address to itself is always 'true'
    function isTransferApproved(address from, address to) public view override returns (bool) {
        return from == to ? true : _isTransferApproved[from][to];
    }

    /// @dev Changes authorization status for transfer approval from msg.sender to an address
    /// @param to Address to change allowance status for
    /// @param status The new approval status
    function setApproval(address to, bool status) external override onlyOwner {
        require(to != address(0), "to cannot be 0");
        _setApproval(msg.sender, to, status);
    }

    /// @param from The owner address
    /// @param to The spender address
    /// @param status Status of approval
    function _setApproval(address from, address to, bool status) internal {
        Registry registry = deviceWallet.registry();
        require(registry.isDeviceWalletValid(to), "Invalid to");

        bool statusChanged = _isTransferApproved[from][to] != status;
        _isTransferApproved[from][to] = status;
        if (statusChanged) {
            emit TransferApprovalChanged(from, to, status);
        }
    }

    /// @dev Internal function to send ETH from this contract
    function _transferETH(address _recipient, uint256 _amount) internal virtual {
        require(address(this).balance >= _amount, "Not enough ETH");
        require(_recipient != address(0), "_recipient 0");

        if (_amount > 0) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert FailedToTransfer();
            else emit ETHSent(_recipient, _amount);
        }
    }

    receive() external payable {
        // receive ETH
    }
}
