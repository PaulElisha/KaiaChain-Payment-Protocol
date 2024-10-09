// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/utils/Pausable.sol";
import "@openzeppelin/utils/ReentrancyGuard.sol";
import "@openzeppelin/utils/cryptography/ECDSA.sol";
import "@openzeppelin/access/Ownable.sol";
import "@openzeppelin/utils/Context.sol";
import "./KaiaSweeper.sol";
import "../src/interfaces/IKaiaTransfer.sol";
import "./interfaces/IWrappedNativeCurrency.sol";

contract KaiaTransfer is
    Context,
    Ownable,
    Pausable,
    ReentrancyGuard,
    KaiaSweeper,
    IKaiaTransfer
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IWrappedNativeCurrency;

    address private immutable NATIVE_CURRENCY =
        0x0000000000000000000000000000000000000000;

    mapping(address => address) private operatorFeeDest;

    mapping(address => mapping(bytes16 => bool))
        private processedTransferIntents;

    IWrappedNativeCurrency private immutable wrappedNativeCurrency;

    constructor(
        address _initialOperator,
        address _initialFeeDestination,
        IWrappedNativeCurrency _wrappedNativeCurrency
    ) {
        require(
            address(_wrappedNativeCurrency) != address(0) &&
                _initialOperator != address(0) &&
                _initialFeeDestination != address(0),
            "invalid constructor parameters"
        );
        wrappedNativeCurrency = _wrappedNativeCurrency;

        // Sets an initial operator to enable immediate payment processing
        feeDestinations[_initialOperator] = _initialFeeDestination;
    }

    // MODIFIERS

    modifier operatorIsRegistered(TransferIntent calldata _intent) {
        if (feeDestinations[_intent.operator] == address(0))
            revert OperatorNotRegistered();
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
            signedMessageHash = keccak256(
                abi.encodePacked(_intent.prefix, hash)
            );
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

    // PAYMENT METHOD

    function transferNative(
        TransferIntent calldata _intent
    )
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
        if (_intent.recipientCurrency != NATIVE_CURRENCY)
            revert IncorrectCurrency(NATIVE_CURRENCY);

        if (msg.value > 0) {
            // Complete the payment
            transferFundsToDestinations(_intent);
        }

        succeedPayment(_intent, msg.value, NATIVE_CURRENCY, _msgSender());
    }

    function transferTokenWithApproval(
        TransferIntent calldata _intent
    )
        external
        override
        nonReentrant
        whenNotPaused
        validIntent(_intent, _msgSender())
        operatorIsRegistered(_intent)
    {
        // Make sure the recipient wants a token
        if (_intent.recipientCurrency == NATIVE_CURRENCY) {
            revert IncorrectCurrency(_intent.recipientCurrency);
        }

        // Make sure the payer has enough of the payment token
        IERC20 erc20 = IERC20(_intent.recipientCurrency);
        uint256 neededAmount = _intent.recipientAmount + _intent.feeAmount;
        uint256 payerBalance = erc20.balanceOf(_msgSender());
        if (payerBalance < neededAmount) {
            revert InsufficientBalance(neededAmount - payerBalance);
        }

        // Make sure the payer has approved this contract for a sufficient transfer
        uint256 allowance = erc20.allowance(_msgSender(), address(this));
        if (allowance < neededAmount) {
            revert InsufficientAllowance(neededAmount - allowance);
        }

        if (neededAmount > 0) {
            // Record our balance before (most likely zero) to detect fee-on-transfer tokens
            uint256 balanceBefore = erc20.balanceOf(address(this));

            // Transfer the payment token to this contract
            erc20.safeTransferFrom(_msgSender(), address(this), neededAmount);

            // Make sure this is not a fee-on-transfer token
            revertIfInexactTransfer(
                neededAmount,
                balanceBefore,
                erc20,
                address(this)
            );

            // Complete the payment
            transferFundsToDestinations(_intent);
        }

        succeedPayment(
            _intent,
            neededAmount,
            _intent.recipientCurrency,
            _msgSender()
        );
    }

    function wrapAndTransfer(
        TransferIntent calldata _intent
    )
        external
        payable
        override
        nonReentrant
        whenNotPaused
        validIntent(_intent, _msgSender())
        operatorIsRegistered(_intent)
        exactValueSent(_intent)
    {
        // Make sure the recipient wants to receive the wrapped native currency
        if (_intent.recipientCurrency != address(wrappedNativeCurrency)) {
            revert IncorrectCurrency(NATIVE_CURRENCY);
        }

        if (msg.value > 0) {
            // Wrap the sent native currency
            wrappedNativeCurrency.deposit{value: msg.value}();

            // Complete the payment
            transferFundsToDestinations(_intent);
        }

        succeedPayment(_intent, msg.value, NATIVE_CURRENCY, _msgSender());
    }

    // @dev Unwraps into native token and transfers native token (e.g. ETH) to _intent.recipient.
    function unwrapAndTransferWithApproval(
        TransferIntent calldata _intent
    )
        external
        override
        nonReentrant
        whenNotPaused
        validIntent(_intent, _msgSender())
        operatorIsRegistered(_intent)
    {
        // Make sure the recipient wants the native currency
        if (_intent.recipientCurrency != NATIVE_CURRENCY) {
            revert IncorrectCurrency(address(wrappedNativeCurrency));
        }

        // Make sure the payer has enough of the wrapped native currency
        uint256 neededAmount = _intent.recipientAmount + _intent.feeAmount;
        uint256 payerBalance = wrappedNativeCurrency.balanceOf(_msgSender());
        if (payerBalance < neededAmount) {
            revert InsufficientBalance(neededAmount - payerBalance);
        }

        // Make sure the payer has approved this contract for a sufficient transfer
        uint256 allowance = wrappedNativeCurrency.allowance(
            _msgSender(),
            address(this)
        );
        if (allowance < neededAmount) {
            revert InsufficientAllowance(neededAmount - allowance);
        }

        if (neededAmount > 0) {
            // Transfer the payer's wrapped native currency to the contract
            wrappedNativeCurrency.safeTransferFrom(
                _msgSender(),
                address(this),
                neededAmount
            );

            // Complete the payment
            unwrapAndTransferFundsToDestinations(_intent);
        }

        succeedPayment(
            _intent,
            neededAmount,
            address(wrappedNativeCurrency),
            _msgSender()
        );
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

    // UTILS FUNCTION

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

    function transferFundsToDestinations(
        TransferIntent calldata _intent
    ) internal {
        if (_intent.recipientCurrency == NATIVE_CURRENCY) {
            if (_intent.recipientAmount > 0) {
                sendNative(_intent.recipient, _intent.recipientAmount, false);
            }
            if (_intent.feeAmount > 0) {
                sendNative(
                    feeDestinations[_intent.operator],
                    _intent.feeAmount,
                    false
                );
            }
        } else {
            IERC20 requestedCurrency = IERC20(_intent.recipientCurrency);
            if (_intent.recipientAmount > 0) {
                requestedCurrency.safeTransfer(
                    _intent.recipient,
                    _intent.recipientAmount
                );
            }
            if (_intent.feeAmount > 0) {
                requestedCurrency.safeTransfer(
                    feeDestinations[_intent.operator],
                    _intent.feeAmount
                );
            }
        }
    }

    function unwrapAndTransferFundsToDestinations(
        TransferIntent calldata _intent
    ) internal {
        uint256 amountToWithdraw = _intent.recipientAmount + _intent.feeAmount;
        if (
            _intent.recipientCurrency == NATIVE_CURRENCY && amountToWithdraw > 0
        ) {
            wrappedNativeCurrency.withdraw(amountToWithdraw);
        }
        transferFundsToDestinations(_intent);
    }

    function sendNative(
        address destination,
        uint256 amount,
        bool isRefund
    ) internal {
        (bool success, bytes memory data) = payable(destination).call{
            value: amount
        }("");
        if (!success) {
            revert NativeTransferFailed(destination, amount, isRefund, data);
        }
    }

    function revertIfInexactTransfer(
        uint256 expectedDiff,
        uint256 balanceBefore,
        IERC20 token,
        address target
    ) internal view {
        uint256 balanceAfter = token.balanceOf(target);
        if (balanceAfter - balanceBefore != expectedDiff) {
            revert InexactTransfer();
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {
        require(
            msg.sender == address(wrappedNativeCurrency),
            "only payable for unwrapping"
        );
    }
}
