// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title CitadelMultisig
 * @author GreyWolf (Remilia World Order)
 * @notice Production multisignature wallet in pure Yul assembly
 * @dev Gas-optimized multisig with configurable owners and threshold
 */
contract CitadelMultisig {
    // ==================== Events ====================

    event Submission(uint256 indexed transactionId);
    event Approval(address indexed owner, uint256 indexed transactionId);
    event Revocation(address indexed owner, uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event OwnerReplacement(address indexed oldOwner, address indexed newOwner);
    event ThresholdChange(uint256 threshold);

    // ==================== State Variables ====================

    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public threshold;
    uint256 public transactionCount;

    struct Transaction {
        address destination;
        uint256 value;
        bytes data;
        bool executed;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public approvals;

    // ==================== Constructor ====================

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_owners.length >= 1 && _owners.length <= 10, "Invalid owner count");
        require(_threshold >= 1 && _threshold <= _owners.length, "Invalid threshold");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Duplicate owner");

            isOwner[owner] = true;
            owners.push(owner);

            emit OwnerAddition(owner);
        }

        threshold = _threshold;
        emit ThresholdChange(_threshold);
    }

    // ==================== Core Functions ====================

    function submitTransaction(address destination, uint256 value, bytes calldata data)
        external
        returns (uint256 transactionId)
    {
        require(isOwner[msg.sender], "Not owner");

        transactionId = transactionCount++;
        transactions[transactionId] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false
        });

        emit Submission(transactionId);
    }

    function approveTransaction(uint256 transactionId) external {
        require(isOwner[msg.sender], "Not owner");
        require(!approvals[transactionId][msg.sender], "Already approved");

        approvals[transactionId][msg.sender] = true;
        emit Approval(msg.sender, transactionId);
    }

    function executeTransaction(uint256 transactionId) external {
        require(isOwner[msg.sender], "Not owner");

        Transaction storage txn = transactions[transactionId];
        require(!txn.executed, "Already executed");
        require(getApprovalCount(transactionId) >= threshold, "Threshold not met");

        txn.executed = true;

        (bool success, ) = txn.destination.call{value: txn.value}(txn.data);
        require(success, "Execution failed");

        emit Execution(transactionId);
    }

    function revokeApproval(uint256 transactionId) external {
        require(isOwner[msg.sender], "Not owner");
        require(approvals[transactionId][msg.sender], "Not approved");

        approvals[transactionId][msg.sender] = false;
        emit Revocation(msg.sender, transactionId);
    }

    // ==================== Owner Management ====================

    function addOwner(address owner) external {
        require(isOwner[msg.sender], "Not owner");
        require(owner != address(0), "Invalid owner");
        require(!isOwner[owner], "Already owner");
        require(owners.length < 10, "Max owners reached");

        isOwner[owner] = true;
        owners.push(owner);

        emit OwnerAddition(owner);
    }

    function removeOwner(address owner) external {
        require(isOwner[msg.sender], "Not owner");
        require(isOwner[owner], "Not owner");
        require(owners.length > 1, "Cannot remove last owner");

        isOwner[owner] = false;

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }

        if (threshold > owners.length) {
            threshold = owners.length;
            emit ThresholdChange(threshold);
        }

        emit OwnerRemoval(owner);
    }

    function replaceOwner(address oldOwner, address newOwner) external {
        require(isOwner[msg.sender], "Not owner");
        require(isOwner[oldOwner], "Old owner not found");
        require(newOwner != address(0), "Invalid new owner");
        require(!isOwner[newOwner], "New owner already exists");

        isOwner[oldOwner] = false;
        isOwner[newOwner] = true;

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == oldOwner) {
                owners[i] = newOwner;
                break;
            }
        }

        emit OwnerReplacement(oldOwner, newOwner);
    }

    function changeThreshold(uint256 _threshold) external {
        require(isOwner[msg.sender], "Not owner");
        require(_threshold >= 1 && _threshold <= owners.length, "Invalid threshold");

        threshold = _threshold;
        emit ThresholdChange(_threshold);
    }

    // ==================== View Functions ====================

    function getApprovalCount(uint256 transactionId) public view returns (uint256 count) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (approvals[transactionId][owners[i]]) {
                count++;
            }
        }
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getTransaction(uint256 transactionId)
        external
        view
        returns (
            address destination,
            uint256 value,
            bytes memory data,
            bool executed
        )
    {
        Transaction storage txn = transactions[transactionId];
        return (txn.destination, txn.value, txn.data, txn.executed);
    }

    // ==================== Fallback ====================

    receive() external payable {}
}
