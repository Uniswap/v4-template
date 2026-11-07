// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {MockSpraay} from "./mocks/MockSpraay.sol";

import {BatchDistributeHook} from "../src/BatchDistributeHook.sol";

contract BatchDistributeHookTest is BaseTest, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    uint256 constant FEE_BPS = 30;

    /// @dev afterInitialize + afterDonate, and nothing else, encoded in the hook address
    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_DONATE_FLAG);

    BatchDistributeHook hook;
    MockSpraay spraay;

    Currency currency0;
    Currency currency1;
    MockERC20 rewardToken;
    PoolKey key;
    PoolId id;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("spraayFeeRecipient");
    address stranger = makeAddr("stranger");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        rewardToken = new MockERC20("Reward", "RWD", 18);

        spraay = new MockSpraay(feeRecipient, FEE_BPS);
        hook = _deployHook(address(spraay));

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        id = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        rewardToken.mint(operator, 1_000_000 ether);
        vm.deal(operator, 1_000_000 ether);
        vm.prank(operator);
        rewardToken.approve(address(hook), type(uint256).max);
    }

    // ============ Setup / hook callbacks ============

    function test_Constructor() public view {
        assertEq(address(hook.spraay()), address(spraay));
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.owner(), owner);
        assertTrue(hook.isOperator(operator));
        assertEq(hook.MAX_RECIPIENTS(), 200);
    }

    function test_Constructor_RevertIfSpraayZero() public {
        address target = address(uint160(HOOK_FLAGS) ^ (0x5555 << 144));
        vm.expectRevert(BatchDistributeHook.ZeroAddress.selector);
        deployCodeTo(
            "BatchDistributeHook.sol:BatchDistributeHook", abi.encode(poolManager, address(0), owner, operator), target
        );
    }

    function test_Constructor_RevertIfAddressFlagsWrong() public {
        // an address with no permission bits set does not match getHookPermissions()
        address target = address(uint160(0x5555 << 144));
        vm.expectRevert();
        deployCodeTo(
            "BatchDistributeHook.sol:BatchDistributeHook",
            abi.encode(poolManager, address(spraay), owner, operator),
            target
        );
    }

    function test_HookPermissions_MatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.afterDonate);
        assertFalse(p.beforeSwap || p.afterSwap || p.beforeAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.beforeSwapReturnDelta || p.afterSwapReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    function test_AfterInitialize_RegistersPool() public view {
        assertTrue(hook.isRegisteredPool(id));
    }

    function test_AfterInitialize_EmitsPoolRegistered() public {
        PoolKey memory key2 = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectEmit(true, false, false, false, address(hook));
        emit BatchDistributeHook.PoolRegistered(key2.toId());
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
        assertTrue(hook.isRegisteredPool(key2.toId()));
    }

    function test_AfterDonate_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit BatchDistributeHook.PoolDonation(id, address(this), 1, 2);
        vm.prank(address(poolManager));
        hook.afterDonate(address(this), key, 1, 2, "");
    }

    /// @dev Full round trip through PoolManager: add liquidity, donate, settle, and observe the hook event
    function test_AfterDonate_ViaPoolManager() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit BatchDistributeHook.PoolDonation(id, address(this), 1 ether, 2 ether);
        poolManager.unlock(abi.encode(uint256(1 ether), uint256(2 ether)));
    }

    function test_HookCallbacks_OnlyPoolManager() public {
        vm.expectRevert();
        hook.afterDonate(address(this), key, 1, 2, "");

        vm.expectRevert();
        hook.afterInitialize(address(this), key, Constants.SQRT_PRICE_1_1, 0);
    }

    // ============ sprayToken path ============

    function test_BatchDistribute_ERC20() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(5, 1 ether);
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = rewardToken.balanceOf(operator);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchDistributed(id, operator, address(rewardToken), 5, total, fee);
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(rewardToken.balanceOf(recipients[i]), amounts[i]);
        }
        assertEq(rewardToken.balanceOf(feeRecipient), fee);
        assertEq(operatorBefore - rewardToken.balanceOf(operator), total + fee);
        // non-custodial: nothing left behind, no dangling approval
        assertEq(rewardToken.balanceOf(address(hook)), 0);
        assertEq(rewardToken.balanceOf(address(spraay)), 0);
        assertEq(rewardToken.allowance(address(hook), address(spraay)), 0);
    }

    function test_BatchDistribute_ERC20_RecipientCounts() public {
        uint256[4] memory counts = [uint256(1), 5, 50, 200];
        for (uint256 c; c < counts.length; ++c) {
            (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(counts[c], 1 ether);
            uint256 operatorBefore = rewardToken.balanceOf(operator);
            uint256[] memory before = new uint256[](recipients.length);
            for (uint256 i; i < recipients.length; ++i) {
                before[i] = rewardToken.balanceOf(recipients[i]);
            }

            vm.prank(operator);
            hook.batchDistribute(id, address(rewardToken), recipients, amounts);

            for (uint256 i; i < recipients.length; ++i) {
                assertEq(rewardToken.balanceOf(recipients[i]) - before[i], amounts[i]);
            }
            assertEq(operatorBefore - rewardToken.balanceOf(operator), total + total * FEE_BPS / 10_000);
            assertEq(rewardToken.balanceOf(address(hook)), 0);
        }
    }

    function test_BatchDistribute_ERC20_RevertIfNativeSent() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.UnexpectedNativeAmount.selector);
        hook.batchDistribute{value: 1}(id, address(rewardToken), recipients, amounts);
    }

    function test_BatchDistribute_ERC20_RevertIfNotApproved() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        rewardToken.approve(address(hook), 0);
        vm.prank(operator);
        vm.expectRevert();
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
    }

    function test_QuoteTotalCost() public view {
        assertEq(hook.quoteTotalCost(10_000), 10_030);
    }

    // ============ sprayETH path ============

    function test_BatchDistribute_Native() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(4, 0.5 ether);
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = operator.balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchDistributed(id, operator, address(0), 4, total, fee);
        vm.prank(operator);
        hook.batchDistribute{value: total + fee}(id, address(0), recipients, amounts);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(recipients[i].balance, amounts[i]);
        }
        assertEq(feeRecipient.balance, fee);
        assertEq(operatorBefore - operator.balance, total + fee);
        assertEq(address(hook).balance, 0);
    }

    function test_BatchDistribute_Native_RefundsExcess() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(3, 1 ether);
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = operator.balance;

        vm.prank(operator);
        hook.batchDistribute{value: total + fee + 7 ether}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, total + fee);
        assertEq(address(hook).balance, 0);
        assertEq(address(spraay).balance, 0);
    }

    function test_BatchDistribute_Native_RevertIfInsufficient() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(3, 1 ether);
        uint256 required = total + total * FEE_BPS / 10_000;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BatchDistributeHook.InsufficientNativeAmount.selector, required, total));
        hook.batchDistribute{value: total}(id, address(0), recipients, amounts);
    }

    // ============ sprayEqual path ============

    function test_BatchDistributeEqual_ERC20() public {
        (address[] memory recipients,,) = _batch(10, 0);
        uint256 amountEach = 3 ether;
        uint256 total = amountEach * 10;
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = rewardToken.balanceOf(operator);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchDistributed(id, operator, address(rewardToken), 10, total, fee);
        vm.prank(operator);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, amountEach);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(rewardToken.balanceOf(recipients[i]), amountEach);
        }
        assertEq(rewardToken.balanceOf(feeRecipient), fee);
        assertEq(operatorBefore - rewardToken.balanceOf(operator), total + fee);
        assertEq(rewardToken.balanceOf(address(hook)), 0);
        assertEq(rewardToken.allowance(address(hook), address(spraay)), 0);
    }

    function test_BatchDistributeEqual_ERC20_RecipientCounts() public {
        uint256[4] memory counts = [uint256(1), 5, 50, 200];
        for (uint256 c; c < counts.length; ++c) {
            (address[] memory recipients,,) = _batch(counts[c], 0);
            uint256 total = 2 ether * counts[c];
            uint256 operatorBefore = rewardToken.balanceOf(operator);
            uint256 lastBefore = rewardToken.balanceOf(recipients[counts[c] - 1]);

            vm.prank(operator);
            hook.batchDistributeEqual(id, address(rewardToken), recipients, 2 ether);

            assertEq(rewardToken.balanceOf(recipients[counts[c] - 1]) - lastBefore, 2 ether);
            assertEq(operatorBefore - rewardToken.balanceOf(operator), total + total * FEE_BPS / 10_000);
        }
    }

    function test_BatchDistributeEqual_Native() public {
        (address[] memory recipients,,) = _batch(6, 0);
        uint256 amountEach = 0.25 ether;
        uint256 total = amountEach * 6;
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = operator.balance;

        vm.prank(operator);
        hook.batchDistributeEqual{value: total + fee + 1 ether}(id, address(0), recipients, amountEach);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(recipients[i].balance, amountEach);
        }
        assertEq(feeRecipient.balance, fee);
        assertEq(operatorBefore - operator.balance, total + fee);
        assertEq(address(hook).balance, 0);
    }

    // ============ Fee ============

    function test_Fee_30Bps() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(1, 0);
        amounts[0] = 10_000 ether;
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
        assertEq(rewardToken.balanceOf(feeRecipient), 30 ether);
    }

    // ============ Access control ============

    function test_RevertIfNotOperator() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(2, 1 ether);
        rewardToken.mint(stranger, 100 ether);
        vm.deal(stranger, 100 ether);

        vm.startPrank(stranger);
        rewardToken.approve(address(hook), type(uint256).max);

        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute{value: total * 2}(id, address(0), recipients, amounts);

        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, 1 ether);
        vm.stopPrank();
    }

    function test_OwnerIsNotImplicitlyOperator() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
    }

    function test_SetOperator() public {
        vm.prank(owner);
        hook.setOperator(stranger, true);
        assertTrue(hook.isOperator(stranger));

        vm.prank(owner);
        hook.setOperator(operator, false);
        assertFalse(hook.isOperator(operator));

        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
    }

    function test_SetOperator_RevertIfNotOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.setOperator(stranger, true);
    }

    function test_SetOperator_RevertIfZero() public {
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.ZeroAddress.selector);
        hook.setOperator(address(0), true);
    }

    function test_SetSpraayContract() public {
        MockSpraay newSpraay = new MockSpraay(feeRecipient, 50);

        vm.expectEmit(true, true, false, false, address(hook));
        emit BatchDistributeHook.SpraayContractUpdated(address(spraay), address(newSpraay));
        vm.prank(owner);
        hook.setSpraayContract(address(newSpraay));
        assertEq(address(hook.spraay()), address(newSpraay));

        // distributions now route through the new contract and its fee
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(2, 1 ether);
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
        assertEq(rewardToken.balanceOf(feeRecipient), total * 50 / 10_000);
    }

    function test_SetSpraayContract_RevertIfNotOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.setSpraayContract(address(1));
    }

    function test_SetSpraayContract_RevertIfZero() public {
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.ZeroAddress.selector);
        hook.setSpraayContract(address(0));
    }

    function test_OwnershipTransfer_TwoStep() public {
        vm.prank(owner);
        hook.transferOwnership(stranger);
        assertEq(hook.owner(), owner);
        assertEq(hook.pendingOwner(), stranger);

        vm.prank(stranger);
        hook.acceptOwnership();
        assertEq(hook.owner(), stranger);
    }

    function test_RescueTokens() public {
        rewardToken.mint(address(hook), 5 ether);
        vm.prank(owner);
        hook.rescueTokens(address(rewardToken), owner, 5 ether);
        assertEq(rewardToken.balanceOf(owner), 5 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.rescueTokens(address(rewardToken), operator, 0);
    }

    // ============ Recipient limits / validation ============

    function test_MaxRecipients_200Succeeds() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(200, 1 ether);
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
        assertEq(rewardToken.balanceOf(recipients[199]), 200 ether);

        vm.prank(operator);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, 1 ether);
        assertEq(rewardToken.balanceOf(recipients[199]), 201 ether);
    }

    function test_MaxRecipients_201Reverts() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(201, 1 ether);
        bytes memory err = abi.encodeWithSelector(BatchDistributeHook.TooManyRecipients.selector, 201, 200);

        vm.startPrank(operator);
        vm.expectRevert(err);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        vm.expectRevert(err);
        hook.batchDistribute{value: total * 2}(id, address(0), recipients, amounts);

        vm.expectRevert(err);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, 1 ether);
        vm.stopPrank();
    }

    function test_RevertIfNoRecipients() public {
        vm.startPrank(operator);
        vm.expectRevert(BatchDistributeHook.NoRecipients.selector);
        hook.batchDistribute(id, address(rewardToken), new address[](0), new uint256[](0));

        vm.expectRevert(BatchDistributeHook.NoRecipients.selector);
        hook.batchDistributeEqual(id, address(rewardToken), new address[](0), 1 ether);
        vm.stopPrank();
    }

    function test_RevertIfLengthMismatch() public {
        (address[] memory recipients,,) = _batch(3, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.LengthMismatch.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, new uint256[](2));
    }

    function test_RevertIfPoolNotRegistered() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.PoolNotRegistered.selector);
        hook.batchDistribute(PoolId.wrap(bytes32(uint256(1))), address(rewardToken), recipients, amounts);
    }

    function test_RevertIfPoolUsesOtherHook() public {
        // same currencies, no hook: a real pool, but not one registered with this hook
        PoolKey memory plain = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(plain, Constants.SQRT_PRICE_1_1);

        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.PoolNotRegistered.selector);
        hook.batchDistribute(plain.toId(), address(rewardToken), recipients, amounts);
    }

    function testFuzz_BatchDistribute_ERC20(uint8 count, uint96 amountEach) public {
        count = uint8(bound(count, 1, 200));
        amountEach = uint96(bound(amountEach, 1, 10 ether));
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(count, amountEach);
        uint256 operatorBefore = rewardToken.balanceOf(operator);

        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        assertEq(operatorBefore - rewardToken.balanceOf(operator), total + total * FEE_BPS / 10_000);
        assertEq(rewardToken.balanceOf(address(hook)), 0);
    }

    // ============ PoolManager unlock callback (used by the donate round trip) ============

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));

        (BalanceDelta added,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100 ether, salt: 0}), ""
        );
        BalanceDelta donated = poolManager.donate(key, amount0, amount1, "");

        currency0.settle(poolManager, address(this), uint256(-int256(added.amount0() + donated.amount0())), false);
        currency1.settle(poolManager, address(this), uint256(-int256(added.amount1() + donated.amount1())), false);
        return "";
    }

    // ============ Helpers ============

    function _deployHook(address spraayAddr) internal returns (BatchDistributeHook) {
        // V4 reads permissions from the hook address, so place the code at an address with the right flags
        address target = address(HOOK_FLAGS ^ (0x4444 << 144));
        deployCodeTo(
            "BatchDistributeHook.sol:BatchDistributeHook", abi.encode(poolManager, spraayAddr, owner, operator), target
        );
        return BatchDistributeHook(payable(target));
    }

    /// @dev Builds `count` fresh EOA recipients; amounts vary per recipient (amountEach * (i + 1))
    function _batch(uint256 count, uint256 amountEach)
        internal
        returns (address[] memory recipients, uint256[] memory amounts, uint256 total)
    {
        recipients = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            recipients[i] = makeAddr(string.concat("recipient", vm.toString(i)));
            amounts[i] = amountEach * (i + 1);
            total += amounts[i];
        }
    }
}
