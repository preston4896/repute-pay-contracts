// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {JobsManager} from "../src/JobsManager.sol";
import {DeploymentConfig} from "./utils/DeploymentConfig.sol";
import {JOBS_MANAGER_SALT} from "./utils/Salt.sol";

contract JobsManagerScript is Script, DeploymentConfig {
    function run() external {
        vm.startBroadcast();

        JobsManager jobsManager = new JobsManager{salt: JOBS_MANAGER_SALT}(4896);
        console.log("JobsManager deployed at: ", address(jobsManager));

        vm.stopBroadcast();

        writeToJson("JobsManager", address(jobsManager));
    }
}
