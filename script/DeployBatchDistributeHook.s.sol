// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {BatchDistributeHook} from "../src/BatchDistributeHook.sol";
import {SpraayAddresses} from "../src/SpraayAddresses.sol";

/**
 * Mines a CREATE2 salt whose resulting address encodes the hook's permissions
 * (afterInitialize + afterDonate) and deploys BatchDistributeHook through the
 * deterministic CREATE2 deployer.
 *
 * Supported chains: Base (8453), BNB Chain (56) — wherever Spraay and the V4 PoolManager are both live.
 *
 * Step 1: Deploy
 * HOOK_OWNER=<owner> HOOK_OPERATOR=<operator> \
 * forge script script/DeployBatchDistributeHook.s.sol:DeployBatchDistributeHookScript -vvv \
 *     --rpc-url base \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Step 2: Verify (Basescan / BscScan via Etherscan V2)
 * forge verify-contract <hook> src/BatchDistributeHook.sol:BatchDistributeHook --watch \
 *     --chain <chain_id> --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
 *     <poolManager> <spraay> <owner> <operator>)
 */
contract DeployBatchDistributeHookScript is Script {
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_DONATE_FLAG);

    function run() public returns (BatchDistributeHook hook) {
        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        address spraay = SpraayAddresses.forChain(block.chainid);
        address owner = vm.envAddress("HOOK_OWNER");
        address operator = vm.envOr("HOOK_OPERATOR", address(0));

        console2.log("PoolManager", address(poolManager));
        console2.log("Spraay     ", spraay);
        console2.log("Owner      ", owner);
        console2.log("Operator   ", operator);

        bytes memory constructorArgs = abi.encode(poolManager, spraay, owner, operator);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(BatchDistributeHook).creationCode, constructorArgs);
        console2.log("Mined hook address", hookAddress);
        console2.logBytes32(salt);

        vm.startBroadcast();
        hook = new BatchDistributeHook{salt: salt}(poolManager, spraay, owner, operator);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployBatchDistributeHookScript: hook address mismatch");
        console2.log("BatchDistributeHook", address(hook));
        console2.log("Verify with:");
        console2.log(
            string.concat(
                "forge verify-contract ",
                vm.toString(address(hook)),
                " src/BatchDistributeHook.sol:BatchDistributeHook --watch --chain ",
                vm.toString(block.chainid),
                " --constructor-args ",
                vm.toString(constructorArgs)
            )
        );
    }
}
