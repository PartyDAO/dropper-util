// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { PRBTest } from "@prb/test/src/PRBTest.sol";
import { console2 } from "forge-std/src/console2.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";

import { Dropper } from "../src/Dropper.sol";

contract DropperTest is PRBTest, StdCheats {
    Dropper dropper;

    function setUp() public {
        dropper = new Dropper();
    }
}

