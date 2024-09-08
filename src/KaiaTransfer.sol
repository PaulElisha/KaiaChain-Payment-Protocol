// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import './interfaces/IKaiaTransfer.sol';
import './KaiaSweeper.sol';
import 'permit2/src/Permit2.sol';

contract KaiaTransfer is Context, Ownable, Pausable, ReentrancyGuard, KaiaSweeper, IKaiaTransfer {

    address private immutable NATIVE_CURRENCY = KLAY;

    mapping(address => address) private operatorFeeDest;

    mapping(address operator => mapping(bytes16 id => bool))
        private processedTransferIntents;


    ////////////////////////////////////////////////////////////////////////////// 
                                MODIFIERS
    //////////////////////////////////////////////////////////////////////////////

    modifier operatorIsRegistered(TransferIntent calldata _intent) {
        if (feeDestinations[_intent.operator] == address(0)) revert OperatorNotRegistered();
        _;  
    }

    modifier exactValueSent(TransferIntent calldata _intent) {
        uint256 neededAmount = _intent.recipientAmount + _intent.feeAmount;
        if (msg.value > neededAmount) {
            revert InvalidNativeAmount(int256(msg.value - neededAmount));
        } else if (msg.value < neededAmount) {
            revert InvalidNativeAmount(-int256(neededAmount - msg.value));
        }

        _;
    }

    modifier validIntent(TransferIntent calldata _intent, address sender) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                _intent.recipientAmount,
                _intent.deadline,
                _intent.recipient,
                _intent.recipientCurrency,
                _intent.refundDestination,
                _intent.feeAmount,
                _intent.id,
                _intent.operator,
                block.chainid,
                sender,
                address(this)
            )
        );

        bytes32 signedMessageHash;
        if (_intent.prefix.length == 0) {
            // Use 'default' message prefix.
            signedMessageHash = ECDSA.toEthSignedMessageHash(hash);
        } else {
            // Use custom message prefix.
            signedMessageHash = keccak256(abi.encodePacked(_intent.prefix, hash));
        }

        address signer = ECDSA.recover(signedMessageHash, _intent.signature);

        if (signer != _intent.operator) {
            revert InvalidSignature();
        }

        if (_intent.deadline < block.timestamp) {
            revert ExpiredIntent();
        }

        if (_intent.recipient == address(0)) {
            revert NullRecipient();
        }

        if (processedTransferIntents[_intent.operator][_intent.id]) {
            revert AlreadyProcessed();
        }

        _;
    }

    ////////////////////////////////////////////////////////////////////////////// 
                                UTILS FUNCTION
    //////////////////////////////////////////////////////////////////////////////

    function succeedPayment(
        TransferIntent calldata _intent,
        uint256 spentAmount,
        address spentCurrency,
        address sender
    ) internal {
        processedTransferIntents[_intent.operator][_intent.id] = true;
        emit Transferred(
            _intent.operator,
            _intent.id,
            _intent.recipient,
            sender,
            spentAmount,
            spentCurrency
        );
    }

    ////////////////////////////////////////////////////////////////////////////// 
                                PAYMENT METHOD
    //////////////////////////////////////////////////////////////////////////////

    function transferNative(TransferIntent calldata _intent)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        validIntent(_intent, _msgSender())
        operatorIsRegistered(_intent)
        exactValueSent(_intent)
    {
        // Make sure the recipient wants the native currency
        if (_intent.recipientCurrency != NATIVE_CURRENCY) revert IncorrectCurrency(NATIVE_CURRENCY);

        if (msg.value > 0) {
            // Complete the payment
            transferFundsToDestinations(_intent);
        }

        succeedPayment(_intent, msg.value, NATIVE_CURRENCY, _msgSender());
    }

    function transferToken(
        TransferIntent calldata _intent,
        Permit2SignatureTransferData calldata _signatureTransferData
    ) external override nonReentrant whenNotPaused validIntent(_intent, _msgSender()) operatorIsRegistered(_intent) {

        if (
            _intent.recipientCurrency == NATIVE_CURRENCY ||
            _signatureTransferData.permit.permitted.token != _intent.recipientCurrency
        ) {
            revert IncorrectCurrency(_signatureTransferData.permit.permitted.token);
        }

        IERC20 erc20 = IERC20(_intent.recipientCurrency);
        uint256 neededAmount = _intent.recipientAmount + _intent.feeAmount;
        uint256 payerBalance = erc20.balanceOf(_msgSender());
        if (payerBalance < neededAmount) {
            revert InsufficientBalance(neededAmount - payerBalance);
        }

        if (neededAmount > 0) {

            if (
                _signatureTransferData.transferDetails.to != address(this) ||
                _signatureTransferData.transferDetails.requestedAmount != neededAmount
            ) {
                revert InvalidTransferDetails();
            }

            uint256 balanceBefore = erc20.balanceOf(address(this));

            permit2.permitTransferFrom(
                _signatureTransferData.permit,
                _signatureTransferData.transferDetails,
                _msgSender(),
                _signatureTransferData.signature
            );

            revertIfInexactTransfer(neededAmount, balanceBefore, erc20, address(this));

            transferFundsToDestinations(_intent);
        }

        succeedPayment(_intent, neededAmount, _intent.recipientCurrency, _msgSender());
    }


    function registerOperatorWithAddressAsFeeDestination() external {
        feeDestinations[_msgSender()] = _msgSender();

        emit OperatorRegistered(_msgSender(), _msgSender());
    }

    function registerOperatorWithAFeeDestination(
        address _feeDestination
    ) external {
        feeDestinations[_msgSender()] = _feeDestination;

        emit OperatorRegistered(_msgSender(), _feeDestination);
    }

    function unregisterOperator() external {
        delete feeDestinations[_msgSender()];

        emit OperatorUnregistered(_msgSender());
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
