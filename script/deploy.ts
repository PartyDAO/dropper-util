import fs from "fs";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { ChildProcessWithoutNullStreams, exec, execSync, spawn } from "child_process";
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
      console.log(validateDeploy("Dropper", { address: "test", deployedArgs: "", version: "1.0.0" }, "11155111"));
    },
  )
  .parse();

async function runDeploy(contract: string, rpcUrl: any, privateKey: any, constructorArgs: any) {
  const contracts = getProjectContracts();
  if (!contracts.includes(contract)) {
    throw new Error(`Contract ${contract} not found in project`);
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const { chainId } = await provider.getNetwork();

  const encodedConstructorArgs = encodeConstructorArgs(contract, constructorArgs);
  let newDeploy: Deploy = { deployedArgs: encodedConstructorArgs } as Deploy;
  newDeploy.version = await getUndeployedContractVersion(contract);

  validateDeploy(contract, newDeploy, chainId.toString());

  const createCommand = `forge create ${contract} --private-key ${privateKey} --rpc-url ${rpcUrl} --verify ${
    !!constructorArgs && constructorArgs.length > 0 ? "--constructor-args " + constructorArgs.join(" ") : ""
  }`;

  const out = await execSync(createCommand);
  const lines = out.toString().split("\n");
  for (const line of lines) {
    if (line.startsWith("Deployed to: ")) {
      // Get the address
      newDeploy.address = line.split("Deployed to: ")[1];
    }
  }

  writeDeploy(contract, newDeploy, chainId.toString());
}

function validateDeploy(contract: string, deploy: Deploy, chainId: string) {
  // First check if deployment file exists
  if (!fs.existsSync(`deployments/${chainId}.json`)) {
    initProject(chainId);
  }
  const existingDeployments = JSON.parse(fs.readFileSync(`deployments/${chainId}.json`, "utf-8"));

  if (
    !!existingDeployments.contracts[contract].deploys.find(
      (d: Deploy) => d.version == deploy.version && d.deployedArgs == deploy.deployedArgs,
    )
  ) {
    throw new Error(
      `Contract ${contract} with version ${deploy.version} and deployed args ${deploy.deployedArgs || "<empty>"} already deployed`,
    );
  }
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

async function launchAnvil(): Promise<ChildProcessWithoutNullStreams> {
  var anvil = spawn("anvil", ["--mnemonic-seed-unsafe", "123"]);
  return new Promise((resolve) => {
    anvil.stdout.on("data", function (data) {
      if (data.includes("Listening")) {
        resolve(anvil);
      }
    });
  });
}

async function getUndeployedContractVersion(contractName: string): Promise<string> {
  const anvil = await launchAnvil();

  const createCommand = `forge create ${contractName} --private-key 0x78427d179c2c0f8467881bc37f9453a99854977507ca53ff65e1c875208a4a03 --rpc-url "127.0.0.1:8545"`;
  let addr = "";

  const out = await execSync(createCommand);
  const lines = out.toString().split("\n");
  for (const line of lines) {
    if (line.startsWith("Deployed to: ")) {
      // Get the address
      addr = line.split("Deployed to: ")[1];
    }
  }

  const res = await getContractVersion(addr, "http://127.0.0.1:8545");
  anvil.kill();

  return res;
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

  if(!fs.existsSync("deployments")) {
    fs.mkdirSync("deployments");
  }

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
