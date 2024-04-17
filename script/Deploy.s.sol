// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { Script } from "forge-std/src/Script.sol";
import { Test } from "forge-std/src/Test.sol";
import { Dropper } from "src/Dropper.sol";
import { Strings } from "openzeppelin-contracts/contracts/utils/Strings.sol";

// Deployment files of the following format: { contractName : { version: address } }

contract DeployScript is Script, Test {
    function run() external {
        uint256 chainId = block.chainid;
        string memory dropperVersion = _getDropperVersion();
        _runDeploymentOfVersion(chainId, dropperVersion);
    }

    struct Deployment {
        address addr;
        string version;
    }

    function _runDeploymentOfVersion(uint256 chainId, string memory contractVersion) internal {
        string memory serializationKey = "deployments";
        string memory filePath = string(abi.encodePacked("deployments/", Strings.toString(chainId), ".json"));
        bool fileExists = vm.exists(filePath);
        string memory fileContent;
        Deployment[] memory existingDeployments;

        if (fileExists) {
            fileContent = vm.readFile(filePath);
            string memory keyToSearch = string(abi.encodePacked("$.Dropper[?(@.version == \"", contractVersion, "\")]"));
            if (vm.keyExistsJson(fileContent, keyToSearch)) {
                require(false, "Contract already deployed");
            }
            existingDeployments = abi.decode(vm.parseJson(fileContent, "$.Dropper"), (Deployment[]));   
        }

        address newContractAddress = _deploy();

        string[] memory serializedDeployments = new string[](existingDeployments.length + 1);
        for (uint256 i = 0; i < existingDeployments.length; i++) {
            Deployment memory deployment = existingDeployments[i];
            serializedDeployments[i] = _serializeDeployment(deployment);
        }

        serializedDeployments[existingDeployments.length] =
            _serializeDeployment(Deployment(newContractAddress, contractVersion));

        string memory newJson = string(abi.encodePacked("[", serializedDeployments[0]));

        for (uint256 i = 1; i < serializedDeployments.length; i++) {
            newJson = string(abi.encodePacked(newJson, ",", serializedDeployments[i]));
        }

        newJson = string(abi.encodePacked(newJson, "]"));

        string memory finalJson = vm.serializeString(serializationKey, "Dropper", newJson);
        vm.writeJson(finalJson, filePath);
    }

    function _serializeDeployment(Deployment memory deployment) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "{\"version\":\"", deployment.version, "\",\"address\":\"", Strings.toHexString(deployment.addr), "\"}"
            )
        );
    }

    function _deploy() internal returns (address) {
        vm.broadcast();
        Dropper dropper = new Dropper();

        return address(dropper);
    }

    function _getDropperVersion() internal returns (string memory) {
        Dropper dropper = new Dropper();
        return dropper.VERSION();
    }
}
