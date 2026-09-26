// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {JobsManager} from "../src/JobsManager.sol";
import {DeploymentConfig} from "./utils/DeploymentConfig.sol";
import {JOBS_MANAGER_SALT} from "./utils/Salt.sol";

contract JobsManagerScript is Script, DeploymentConfig {
    function run() external {
        vm.startBroadcast();

        // TODO: World ID Configuration
        address worldIdVerifier;
        address worldIdServiceVerifier;
        bytes memory worldAppActionBytes = hex"";
        uint64 worldAppRpId;

        uint256 worldAppAction = uint256(keccak256(worldAppActionBytes)) >> 8;

        JobsManager jobsManager = new JobsManager{salt: JOBS_MANAGER_SALT}(
            msg.sender,
            worldIdVerifier,
            worldIdServiceVerifier,
            worldAppAction,
            worldAppRpId
        );
        console.log("JobsManager deployed at: ", address(jobsManager));

        vm.stopBroadcast();

        writeToJson("JobsManager", address(jobsManager));
    }
}
