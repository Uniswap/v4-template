// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {MockSpraay} from "./mocks/MockSpraay.sol";

import {BatchDistributeHook} from "../src/BatchDistributeHook.sol";

/// @dev The minimal custom distributor an operator would otherwise write: loop transferFrom, no fee
contract NaiveDistributor {
    function distribute(MockERC20 token, address[] calldata recipients, uint256[] calldata amounts) external {
        for (uint256 i; i < recipients.length; ++i) {
            token.transferFrom(msg.sender, recipients[i], amounts[i]);
        }
    }
}

/// @notice Gas for one hook distribution vs. the two naive alternatives:
///   - "loop": a single transaction through a minimal loop-transferFrom contract
///   - "N txs": one ERC-20 transfer transaction per recipient (each pays the 21k base cost)
/// Execution gas only (calldata cost excluded). Every recipient is a fresh address, so each
/// transfer pays the cold zero-to-nonzero balance write, the realistic case for airdrops.
/// Run with `forge test --match-contract BatchDistributeHookGasTest -vv` to print the table.
contract BatchDistributeHookGasTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint256 constant TX_BASE_GAS = 21_000;

    BatchDistributeHook hook;
    NaiveDistributor naive;
    MockERC20 token;
    PoolId id;
    address operator = makeAddr("operator");

    function setUp() public {
        deployArtifactsAndLabel();
        MockSpraay spraay = new MockSpraay(makeAddr("feeRecipient"), 30);

        address hookAddr = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_DONATE_FLAG) ^ (0x4444 << 144));
        deployCodeTo(
            "BatchDistributeHook.sol:BatchDistributeHook",
            abi.encode(poolManager, address(spraay), address(this), operator),
            hookAddr
        );
        hook = BatchDistributeHook(payable(hookAddr));
        naive = new NaiveDistributor();

        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory key = PoolKey(c0, c1, 3000, 60, IHooks(hookAddr));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        id = key.toId();

        token = new MockERC20("Reward", "RWD", 18);
        token.mint(operator, type(uint128).max);
        vm.startPrank(operator);
        token.approve(address(hook), type(uint256).max);
        token.approve(address(naive), type(uint256).max);
        vm.stopPrank();
    }

    function test_Gas_Comparison() public {
        uint256[5] memory counts = [uint256(1), 5, 50, 100, 200];
        console2.log("recipients | hook (1 tx) | naive loop (1 tx) | N separate txs");
        for (uint256 c; c < counts.length; ++c) {
            uint256 n = counts[c];
            uint256 hookGas = _measureHook(n, c);
            uint256 loopGas = _measureLoop(n, c);
            uint256 separateGas = n * (TX_BASE_GAS + _measureSingleTransfer(c));

            console2.log(n, hookGas, loopGas, separateGas);
            if (n >= 5) assertLt(hookGas, separateGas, "hook should beat N separate transactions");
        }
    }

    function _measureHook(uint256 n, uint256 round) internal returns (uint256) {
        (address[] memory recipients, uint256[] memory amounts) = _fresh("hook", n, round);
        vm.prank(operator);
        hook.batchDistribute(id, address(token), recipients, amounts);
        return _lastCallGas() + TX_BASE_GAS;
    }

    function _measureLoop(uint256 n, uint256 round) internal returns (uint256) {
        (address[] memory recipients, uint256[] memory amounts) = _fresh("loop", n, round);
        vm.prank(operator);
        naive.distribute(token, recipients, amounts);
        return _lastCallGas() + TX_BASE_GAS;
    }

    function _measureSingleTransfer(uint256 round) internal returns (uint256) {
        (address[] memory recipients,) = _fresh("single", 1, round);
        vm.prank(operator);
        token.transfer(recipients[0], 1 ether);
        return _lastCallGas();
    }

    function _lastCallGas() internal view returns (uint256) {
        Vm.Gas memory gas = vm.lastCallGas();
        return gas.gasTotalUsed;
    }

    function _fresh(string memory tag, uint256 n, uint256 round)
        internal
        pure
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode(tag, round, i)))));
            amounts[i] = 1 ether;
        }
    }
}
