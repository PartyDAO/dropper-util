import fs from "fs";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { exec, execSync } from "child_process";
import { ethers } from "ethers";

yargs(hideBin(process.argv))
  .usage("$0 <cmd> [args]")
  .command(
    "deploy <contract>",
    "deploy the given contract",
    (yargs) => {
      return yargs
        .positional("contract", {
          describe: "contract to deploy",
          type: "string",
          demandOption: "true",
        })
        .describe("rpc", "The URL of the RPC to use for deployment")
        .describe("pk", "The private key to use for deployment")
        .array("constructor-args")
        .string("constructor-args")
        .string("pk")
        .string("rpc")
        .demandOption(["rpc", "pk"]);
    },
    (argv) => {
      runDeploy(argv.contract, argv.rpc, argv.pk, argv["constructor-args"]);
    },
  )
  .command(
    "init <chainId>",
    "initialize the deployment file for a given network",
    (yargs) => {
      return yargs.positional("chainId", {
        describe: "network id to initialize for",
        type: "string",
        demandOption: "true",
      });
    },
    (argv) => {
      initProject(argv.chainId);
    },
  )
  .command(
    "temp",
    "temp func",
    (yargs) => {
      return yargs;
    },
    async (argv) => {
      console.log(await getContractVersion("0x2871e49a08AceE842C8F225bE7BFf9cC311b9F43", "https://sepolia.base.org"));
    },
  )
  .parse();

async function runDeploy(contract: string, rpcUrl: any, privateKey: any, constructorArgs: any) {
  const contracts = getProjectContracts();
  if (!contracts.includes(contract)) {
    throw new Error(`Contract ${contract} not found in project`);
  }

  const createCommand = `forge create ${contract} --private-key ${privateKey} --rpc-url ${rpcUrl} --verify ${
    !!constructorArgs && constructorArgs.length > 0 ? "--constructor-args " + constructorArgs.join(" ") : ""
  }`;

  const encodedConstructorArgs = encodeConstructorArgs(contract, constructorArgs);
  let newDeploy: Deploy = { deployedArgs: encodedConstructorArgs } as Deploy;

  const out = await execSync(createCommand);
  const lines = out.toString().split("\n");
  for (const line of lines) {
    if (line.startsWith("Deployed to: ")) {
      // Get the address
      newDeploy.address = line.split("Deployed to: ")[1];
    }
  }

  newDeploy.version = await getContractVersion(newDeploy.address, rpcUrl);

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const { chainId } = await provider.getNetwork();
  writeDeploy(contract, newDeploy, chainId.toString());
}

function writeDeploy(contract: string, deploy: Deploy, chainId: string) {
  // First check if deployment file exists
  if (!fs.existsSync(`deployments/${chainId}.json`)) {
    initProject(chainId);
  }
  const existingDeployments = JSON.parse(fs.readFileSync(`deployments/${chainId}.json`, "utf-8"));
  existingDeployments.contracts[contract].deploys.push(deploy);
  fs.writeFileSync(`deployments/${chainId}.json`, JSON.stringify(existingDeployments));
}

async function getContractVersion(contractAddress: string, rpcUrl: string): Promise<string> {
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const versionRes = await provider.call({ to: contractAddress, data: "0xffa1ad74" /* Version function */ });
  return ethers.AbiCoder.defaultAbiCoder().decode(["string"], versionRes)[0];
}

function encodeConstructorArgs(contractName: string, args: string[] | undefined): string {
  if (!!args) {
    const contractABI = JSON.parse(fs.readFileSync(`out/${contractName}.sol/${contractName}.json`, "utf-8")).abi;
    const contractInterface = new ethers.Interface(contractABI);
    return contractInterface.encodeDeploy(args);
  }
  return "";
}

type Deploy = {
  version: string;
  address: string;
  deployedArgs: string;
};
type Contract = {
  deploys: Deploy[];
  constructorArgs: string[];
};

/**
 * Initialize the deployment file for a given network
 * @param chainId
 */
function initProject(chainId: string) {
  console.log(`Initializing project for network ${chainId}...`);

  if (fs.existsSync(`deployments/${chainId}.json`)) {
    throw new Error(`Deployment file for network ${chainId} already exists`);
  }

  let fileToStore: { [key: string]: { [key: string]: Contract } | { [key: string]: string } } = {
    contracts: {},
    constants: {},
  };
  const contracts = getProjectContracts();
  contracts.map((contract) => {
    fileToStore.contracts[contract] = {
      deploys: [],
      constructorArgs: [],
    };
  });

  fs.writeFileSync(`deployments/${chainId}.json`, JSON.stringify(fileToStore));
}

function getProjectContracts(): string[] {
  exec("forge build", (err) => {
    if (err) {
      throw new Error("Failed to build project");
    }
  });
  const buildCache = JSON.parse(fs.readFileSync("cache/solidity-files-cache.json", "utf-8"));
  // Get files in src directory
  const filesOfInterest = Object.keys(buildCache.files).filter((file: string) => file.startsWith("src/"));

  // Get contracts that have bytecode
  let deployableContracts: string[] = [];
  for (const file of filesOfInterest) {
    const fileName = file.split("/").pop()!;
    const buildOutput = JSON.parse(fs.readFileSync(`out/${fileName}/${fileName.split(".")[0]}.json`, "utf-8"));
    // Only consider contracts that are deployable
    if (buildOutput.bytecode.object !== "0x") {
      deployableContracts.push(fileName.split(".")[0]);
    }
  }

  return deployableContracts;
}
