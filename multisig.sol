// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IConnext} from "@connext/nxtp-contracts/contracts/core/connext/interfaces/IConnext.sol";
import {IXReceiver} from "@connext/nxtp-contracts/contracts/core/connext/interfaces/IXReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract MultiSigWallet is IXReceiver {

    IConnext public connext;

    event Deposit(address indexed sender, uint amount, uint balance);
    event SubmitTransaction(
        address indexed owner,
        uint indexed txIndex,
        address indexed to,
        uint value,
        bytes data
    );
    event ConfirmTransaction(address indexed owner, uint indexed txIndex);
    event RevokeConfirmation(address indexed owner, uint indexed txIndex);
    event ExecuteTransaction(address indexed owner, uint indexed txIndex);

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint public numConfirmationsRequired;

    struct Transaction {
        address to;
        uint value;
        bytes data;
        bool executed;
        uint numConfirmations;
    }

    // mapping from tx index => owner => bool
    mapping(uint => mapping(address => bool)) public isConfirmed;

    Transaction[] public transactions;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "not owner");
        _;
    }

    modifier txExists(uint _txIndex) {
        require(_txIndex < transactions.length, "tx does not exist");
        _;
    }

    modifier notExecuted(uint _txIndex) {
        require(!transactions[_txIndex].executed, "tx already executed");
        _;
    }

    modifier notConfirmed(uint _txIndex) {
        require(!isConfirmed[_txIndex][msg.sender], "tx already confirmed");
        _;
    }

    constructor(address[] memory _owners, uint _numConfirmationsRequired, IConnext _connext) {
        require(_owners.length > 0, "owners required");
        require(
            _numConfirmationsRequired > 0 &&
                _numConfirmationsRequired <= _owners.length,
            "invalid number of required confirmations"
        );

        for (uint i = 0; i < _owners.length; i++) {
            address owner = _owners[i];

            require(owner != address(0), "invalid owner");
            require(!isOwner[owner], "owner not unique");

            isOwner[owner] = true;
            owners.push(owner);
        }

        numConfirmationsRequired = _numConfirmationsRequired;
        connext = _connext;

    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    function submitTransaction(
        address _to,
        uint _value,
        bytes memory _data
    ) public onlyOwner {
        uint txIndex = transactions.length;

        transactions.push(
            Transaction({
                to: _to,
                value: _value,
                data: _data,
                executed: false,
                numConfirmations: 0
            })
        );

        emit SubmitTransaction(msg.sender, txIndex, _to, _value, _data);
    }

    function confirmTransaction(uint _txIndex)
        public
        onlyOwner
        txExists(_txIndex)
        notExecuted(_txIndex)
        notConfirmed(_txIndex)
    {
        Transaction storage transaction = transactions[_txIndex];
        transaction.numConfirmations += 1;
        isConfirmed[_txIndex][msg.sender] = true;

        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    function executeTransaction(uint _txIndex)
        public
        onlyOwner
        txExists(_txIndex)
        notExecuted(_txIndex)
    {
        Transaction storage transaction = transactions[_txIndex];

        require(
            transaction.numConfirmations >= numConfirmationsRequired,
            "cannot execute tx"
        );

        transaction.executed = true;

        (bool success, ) = transaction.to.call{value: transaction.value}(
            transaction.data
        );
        require(success, "tx failed");

        emit ExecuteTransaction(msg.sender, _txIndex);
    }

    function revokeConfirmation(uint _txIndex)
        public
        onlyOwner
        txExists(_txIndex)
        notExecuted(_txIndex)
    {
        Transaction storage transaction = transactions[_txIndex];

        require(isConfirmed[_txIndex][msg.sender], "tx not confirmed");

        transaction.numConfirmations -= 1;
        isConfirmed[_txIndex][msg.sender] = false;

        emit RevokeConfirmation(msg.sender, _txIndex);
    }

    function getOwners() public view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() public view returns (uint) {
        return transactions.length;
    }

    function getTransaction(uint _txIndex)
        public
        view
        returns (
            address to,
            uint value,
            bytes memory data,
            bool executed,
            uint numConfirmations
        )
    {
        Transaction storage transaction = transactions[_txIndex];

        return (
            transaction.to,
            transaction.value,
            transaction.data,
            transaction.executed,
            transaction.numConfirmations
        );
    }

    event fundsRecieved(uint256 amount, address asset);

    function xReceive(
        bytes32 _transferId,
        uint256 _amount,
        address _asset,
        address _originSender,
        uint32 _origin,
        bytes memory _callData
    ) external returns (bytes memory) {
        // Enforce the cost to update the greeting
        require(_amount >= 0, "Must pay at least 1 TEST");
        // Unpack the _callData
        string memory txType;
        uint256 _txIndex;
        (txType,_txIndex) = abi.decode(_callData, (string, uint256));

        if(keccak256(abi.encodePacked("approve")) == keccak256(abi.encodePacked(txType))){
                    Transaction storage transaction = transactions[_txIndex];
                    transaction.numConfirmations += 1;
                    isConfirmed[_txIndex][_originSender] = true;
                    emit ConfirmTransaction(msg.sender, _txIndex);
        }else if(1>2){
            emit fundsRecieved(_amount, _asset);
        }
    }


    function approveForAnotherChain(address target, uint32 destinationDomain, uint256 relayerFee, uint256 txIndex) public onlyOwner{
            // Encode the data needed for the target contract call.
            bytes memory callData = abi.encode("approve", txIndex);
            connext.xcall{value: relayerFee}(
            destinationDomain, // _destination: Domain ID of the destination chain
            target,            // _to: address of the target contract
            address(0),    // _asset: address of the token contract
            msg.sender,        // _delegate: address that can revert or forceLocal on destination
            0,              // _amount: amount of tokens to transfer
            0,                // _slippage: the max slippage the user will accept in BPS (0.3%)
            callData           // _callData: the encoded calldata to send
            );
    }

    function transferFundsToAnotherChain(address target, uint32 destinationDomain, uint256 relayerFee, uint256 amount, address tokenAddress) public onlyOwner{
            require(
                IERC20(tokenAddress).balanceOf(address(this)) >= amount,
                "User must approve amount"
            );
            // Encode the data needed for the target contract call.
            bytes memory callData = abi.encode("transfer");
            IERC20(tokenAddress).approve(address(connext), amount);

            connext.xcall{value: relayerFee}(
                destinationDomain, // _destination: Domain ID of the destination chain
                target,            // _to: address of the target contract
                address(tokenAddress),    // _asset: address of the token contract
                msg.sender,        // _delegate: address that can revert or forceLocal on destination
                amount,              // _amount: amount of tokens to transfer
                30,                // _slippage: the max slippage the user will accept in BPS (0.3%)
                callData           // _callData: the encoded calldata to send
            );
    }

}
