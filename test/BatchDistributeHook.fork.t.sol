// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {BatchDistributeHook} from "../src/BatchDistributeHook.sol";
import {ISpraay} from "../src/interfaces/ISpraay.sol";
import {SpraayAddresses} from "../src/SpraayAddresses.sol";

/// @notice Runs the hook against the live Spraay and Uniswap V4 PoolManager deployments.
/// Skipped unless BASE_RPC_URL / BSC_RPC_URL are set, e.g.
///   BASE_RPC_URL=https://mainnet.base.org BSC_RPC_URL=https://bsc-dataseed.binance.org \
///     forge test --match-contract BatchDistributeHookForkTest
contract BatchDistributeHookForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_DONATE_FLAG);

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    function test_Fork_Base() public {
        _runFork("BASE_RPC_URL", 8453);
    }

    function test_Fork_BSC() public {
        _runFork("BSC_RPC_URL", 56);
    }

    function _runFork(string memory rpcEnv, uint256 chainId) internal {
        string memory rpc = vm.envOr(rpcEnv, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, chainId);

        (BatchDistributeHook hook, PoolId id, uint256 feeBps) = _deployOnFork(chainId);
        _exercise(hook, id, feeBps);
    }

    function _deployOnFork(uint256 chainId) internal returns (BatchDistributeHook hook, PoolId id, uint256 feeBps) {
        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(chainId));
        address spraayAddr = SpraayAddresses.forChain(chainId);
        assertGt(address(poolManager).code.length, 0, "PoolManager not deployed");

        ISpraay spraay = ISpraay(spraayAddr);
        feeBps = spraay.feeBps();
        assertEq(spraay.MAX_RECIPIENTS(), 200);

        address hookAddr = address(HOOK_FLAGS ^ (0x4444 << 144));
        deployCodeTo(
            "BatchDistributeHook.sol:BatchDistributeHook",
            abi.encode(poolManager, spraayAddr, owner, operator),
            hookAddr
        );
        hook = BatchDistributeHook(payable(hookAddr));

        // a fresh pool on the live PoolManager that uses the hook
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (address t0, address t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        PoolKey memory key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(hookAddr));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        id = key.toId();
        assertTrue(hook.isRegisteredPool(id));
    }

    function _exercise(BatchDistributeHook hook, PoolId id, uint256 feeBps) internal {
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            recipients[i] = makeAddr(string.concat("forkRecipient", vm.toString(i)));
            amounts[i] = (i + 1) * 1 ether;
        }
        uint256 total = 6 ether;
        uint256 required = total + total * feeBps / 10_000;
        assertEq(hook.quoteTotalCost(total), required);

        // ERC-20 via sprayToken
        MockERC20 reward = new MockERC20("R", "R", 18);
        reward.mint(operator, 1_000 ether);
        vm.startPrank(operator);
        reward.approve(address(hook), type(uint256).max);
        hook.batchDistribute(id, address(reward), recipients, amounts);
        // ERC-20 via sprayEqual
        hook.batchDistributeEqual(id, address(reward), recipients, 1 ether);
        vm.stopPrank();

        assertEq(reward.balanceOf(recipients[0]), 2 ether);
        assertEq(reward.balanceOf(recipients[2]), 4 ether);
        assertEq(1_000 ether - reward.balanceOf(operator), required + 3 ether + 3 ether * feeBps / 10_000);
        assertEq(reward.balanceOf(address(hook)), 0);

        // native via sprayETH, with excess refunded
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        hook.batchDistribute{value: required + 1 ether}(id, address(0), recipients, amounts);
        assertEq(recipients[1].balance, 2 ether);
        assertEq(operator.balance, 100 ether - required);
        assertEq(address(hook).balance, 0);
    }
}
