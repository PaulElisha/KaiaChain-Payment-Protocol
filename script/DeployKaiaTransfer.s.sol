// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/KaiaTransfer.sol";

contract DeployKaiaTransfer is Script {
    function deployKaiaTransfer() public returns (KaiaTransfer) {
        vm.startBroadcast();
        KaiaTransfer kaiaTransfer = new KaiaTransfer();
        vm.stopBroadcast();

        return kaiaTransfer;
    }

    function run() public returns (KaiaTransfer) {
        return deployKaiaTransfer();
    }
}
