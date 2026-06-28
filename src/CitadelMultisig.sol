// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title CitadelMultisig
 * @author GreyWolf (Remilia World Order)
 * @notice Production multisignature wallet with threshold-enforced governance.
 * @dev All owner-set and threshold changes require multisig approval: encode the call to
 *      address(this) and route it through submitTransaction → approveTransaction → executeTransaction.
 *      No single owner can unilaterally alter the signer set or threshold.
 */
contract CitadelMultisig {
    // ==================== Events ====================

    event Submission(uint256 indexed transactionId);
    event Approval(address indexed owner, uint256 indexed transactionId);
    event Revocation(address indexed owner, uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event ExecutionFailure(uint256 indexed transactionId);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event OwnerReplacement(address indexed oldOwner, address indexed newOwner);
    event ThresholdChange(uint256 threshold);
    event Deposit(address indexed sender, uint256 value);

    // ==================== Constants ====================

    uint256 public constant MAX_OWNERS = 50;

    // ==================== State Variables ====================

    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public threshold;
    uint256 public transactionCount;

    // Reentrancy guard: 1 = not entered, 2 = entered.
    uint256 private _guardStatus;

    struct Transaction {
        address destination;
        uint256 value;
        bytes data;
        bool executed;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public approvals;

    // ==================== Modifiers ====================

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not owner");
        _;
    }

    // Governance functions are restricted to calls originating from executeTransaction,
    // meaning the full multisig threshold must be satisfied before any governance change.
    modifier onlyWallet() {
        require(msg.sender == address(this), "Only via multisig");
        _;
    }

    modifier nonReentrant() {
        require(_guardStatus != 2, "Reentrant call");
        _guardStatus = 2;
        _;
        _guardStatus = 1;
    }

    modifier txExists(uint256 transactionId) {
        require(transactionId < transactionCount, "Tx does not exist");
        _;
    }

    modifier notExecuted(uint256 transactionId) {
        require(!transactions[transactionId].executed, "Already executed");
        _;
    }

    // ==================== Constructor ====================

    constructor(address[] memory _owners, uint256 _threshold) {
        uint256 len = _owners.length;
        require(len >= 1 && len <= MAX_OWNERS, "Invalid owner count");
        require(_threshold >= 1 && _threshold <= len, "Invalid threshold");

        for (uint256 i = 0; i < len; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Zero address owner");
            require(owner != address(this), "Contract cannot be owner");
            require(!isOwner[owner], "Duplicate owner");

            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAddition(owner);
        }

        threshold = _threshold;
        _guardStatus = 1;
        emit ThresholdChange(_threshold);
    }

    // ==================== Core Functions ====================

    /**
     * @notice Submit a transaction proposal. The submitter's approval is recorded automatically.
     * @param destination Target address. Must not be address(0).
     * @param value       ETH value to forward.
     * @param data        Calldata to forward.
     * @return transactionId Assigned transaction index.
     */
    function submitTransaction(
        address destination,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (uint256 transactionId) {
        require(destination != address(0), "Zero address destination");

        transactionId = transactionCount++;
        transactions[transactionId] = Transaction({
            destination: destination,
            value: value,
            data: data,
            executed: false
        });

        emit Submission(transactionId);

        // Auto-approve for the submitter so they do not need a second call.
        approvals[transactionId][msg.sender] = true;
        emit Approval(msg.sender, transactionId);
    }

    function approveTransaction(uint256 transactionId)
        external
        onlyOwner
        txExists(transactionId)
        notExecuted(transactionId)
    {
        require(!approvals[transactionId][msg.sender], "Already approved");

        approvals[transactionId][msg.sender] = true;
        emit Approval(msg.sender, transactionId);
    }

    /**
     * @notice Execute a transaction once the approval threshold is met.
     * @dev Uses a reentrancy guard. If the external call fails the transaction is not marked
     *      executed so it can be retried after the underlying issue is resolved.
     *      The original revert reason from the callee is bubbled up.
     */
    function executeTransaction(uint256 transactionId)
        external
        onlyOwner
        txExists(transactionId)
        notExecuted(transactionId)
        nonReentrant
    {
        require(getApprovalCount(transactionId) >= threshold, "Threshold not met");

        Transaction storage txn = transactions[transactionId];

        // Checks-effects-interactions: mark executed before the call.
        txn.executed = true;

        (bool success, bytes memory returnData) =
            txn.destination.call{value: txn.value}(txn.data);

        if (!success) {
            // Undo the executed flag so the transaction can be retried.
            txn.executed = false;
            emit ExecutionFailure(transactionId);
            // Bubble up the callee's revert reason.
            uint256 returnDataLen = returnData.length;
            if (returnDataLen > 0) {
                assembly {
                    revert(add(returnData, 32), returnDataLen)
                }
            }
            revert("Execution failed");
        }

        emit Execution(transactionId);
    }

    function revokeApproval(uint256 transactionId)
        external
        onlyOwner
        txExists(transactionId)
        notExecuted(transactionId)
    {
        require(approvals[transactionId][msg.sender], "Not approved");

        approvals[transactionId][msg.sender] = false;
        emit Revocation(msg.sender, transactionId);
    }

    // ==================== Owner Management (onlyWallet) ====================
    // SECURITY: These functions require msg.sender == address(this).
    // They are only reachable by encoding the calldata and submitting it as a multisig
    // transaction to address(this), then reaching the approval threshold.

    function addOwner(address owner) external onlyWallet {
        require(owner != address(0), "Zero address owner");
        require(owner != address(this), "Contract cannot be owner");
        require(!isOwner[owner], "Already owner");
        require(owners.length < MAX_OWNERS, "Max owners reached");

        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAddition(owner);
    }

    function removeOwner(address owner) external onlyWallet {
        require(isOwner[owner], "Not owner");
        require(owners.length > 1, "Cannot remove last owner");

        isOwner[owner] = false;

        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
        }

        // Auto-reduce threshold if it would exceed the new owner count.
        if (threshold > owners.length) {
            threshold = owners.length;
            emit ThresholdChange(threshold);
        }

        emit OwnerRemoval(owner);
    }

    function replaceOwner(address oldOwner, address newOwner) external onlyWallet {
        require(isOwner[oldOwner], "Old owner not found");
        require(newOwner != address(0), "Zero address new owner");
        require(newOwner != address(this), "Contract cannot be owner");
        require(!isOwner[newOwner], "New owner already exists");

        isOwner[oldOwner] = false;
        isOwner[newOwner] = true;

        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (owners[i] == oldOwner) {
                owners[i] = newOwner;
                break;
            }
        }

        emit OwnerReplacement(oldOwner, newOwner);
    }

    function changeThreshold(uint256 _threshold) external onlyWallet {
        require(_threshold >= 1 && _threshold <= owners.length, "Invalid threshold");

        threshold = _threshold;
        emit ThresholdChange(_threshold);
    }

    // ==================== View Functions ====================

    function getApprovalCount(uint256 transactionId) public view returns (uint256 count) {
        uint256 len = owners.length;
        for (uint256 i = 0; i < len; i++) {
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

    /**
     * @notice Returns true if the transaction exists, is not yet executed, and has reached threshold.
     */
    function canExecute(uint256 transactionId) external view returns (bool) {
        if (transactionId >= transactionCount) return false;
        if (transactions[transactionId].executed) return false;
        return getApprovalCount(transactionId) >= threshold;
    }

    // ==================== Fallback ====================

    receive() external payable {
        if (msg.value > 0) emit Deposit(msg.sender, msg.value);
    }
}
