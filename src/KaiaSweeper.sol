// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@kaia/utils/Context.sol";
import "@kaia/access/Ownable.sol";
import "@kaia/token/ERC20/IERC20.sol";
import "@kaia/token/ERC20/utils/SafeERC20.sol";

error KaiaSweeper__OnlyOwner();
error KaiaSweeper__ZeroAddress();
error KaiaSweeper__ZeroBalance();
error KaiaSweeper__TransferError();
error KaiaSweeper__InsufficientBalance();

abstract contract KaiaSweeper is Context {
    using SafeERC20 for IERC20;

    address private owner;

    modifier onlyOwner() {
        if (_owner() != _msgSender()) revert KaiaSweeper__OnlyOwner();
        _;
    }

    modifier notZero(address a) {
        if (a == address(0)) revert KaiaSweeper__ZeroAddress();
        _;
    }

    function _owner() public view virtual returns (address) {
        return owner;
    }

    function setSweeper(
        address newOwner
    ) public virtual onlyOwner notZero(newOwner) {
        owner = newOwner;
    }

    function sweepKLAY(
        address payable destination
    ) public virtual onlyOwner notZero(destination) {
        uint256 balance = address(this).balance;
        if (balance <= 0) revert KaiaSweeper__ZeroBalance();
        (bool success, ) = destination.call{value: balance}("");
        if (!success) revert KaiaSweeper__TransferError();
    }

    function sweepKLAYAmount(
        address payable destination,
        uint256 amount
    ) public virtual onlyOwner notZero(destination) {
        uint256 balance = address(this).balance;
        if (balance < amount) revert KaiaSweeper__InsufficientBalance();
        (bool success, ) = destination.call{value: amount}("");
        if (!success) revert KaiaSweeper__TransferError();
    }

    function sweepToken(
        address _token,
        address destination
    ) public virtual onlyOwner notZero(destination) {
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        if (balance <= 0) revert KaiaSweeper__ZeroBalance();
        token.safeTransfer(destination, balance);
    }

    function sweepTokenAmount(
        address _token,
        address destination,
        uint256 amount
    ) public virtual onlyOwner notZero(destination) {
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert KaiaSweeper__InsufficientBalance();
        token.safeTransfer(destination, amount);
    }
}
