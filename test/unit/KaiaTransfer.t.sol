// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/KaiaTransfer.sol";
import "../../script/DeployKaiaTransfer.s.sol";

contract KaiaTransferTest is Test {
    KaiaTransfer public kaiaTransfer;

    function setUp() public {
        DeployKaiaTransfer deployKaiaTransfer = new DeployKaiaTransfer();
        kaiaTransfer = deployKaiaTransfer.run();
    }
}
