// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {Test, console2} from "@forge-std/Test.sol";
import {TestBaseProtocol} from "@test/base/TestBaseProtocol.sol";
import {TestBaseGnosis} from "@test/base/TestBaseGnosis.sol";
import {SafeL2} from "@safe-contracts/SafeL2.sol";
import {TradingModule} from "@src/modules/trading/TradingModule.sol";
import {ITradingModule} from "@src/interfaces/ITradingModule.sol";
import {Enum} from "@safe-contracts/common/Enum.sol";
import {SafeUtils, SafeTransaction} from "@test/utils/SafeUtils.sol";
import {IBeforeTransaction, IAfterTransaction} from "@src/interfaces/ITransactionHooks.sol";
import "@src/lib/Hooks.sol";
import "@src/modules/trading/HookRegistry.sol";
import "@src/modules/trading/Errors.sol";
import "@src/modules/trading/Structs.sol";

contract MockTarget {
    uint256 public value;

    event Message(string message);

    function increment(uint256 _value) public {
        value += _value;
    }

    function triggerRevert() public {
        revert("MockTarget revert");
    }

    function emitMessage(string memory message) public payable returns (string memory) {
        emit Message(message);

        return message;
    }
}

contract VerifyValueHook is IBeforeTransaction {
    function checkBeforeTransaction(address, bytes4, uint8, uint256 value, bytes memory)
        external
        override
    {
        require(value > 0, "Value must be greater than 0");
    }
}

contract RevertBeforeHook is IBeforeTransaction {
    function checkBeforeTransaction(address, bytes4, uint8, uint256, bytes memory)
        external
        override
    {
        revert("RevertBeforeHook");
    }
}

contract VerifyCallbackHook is IAfterTransaction {
    string internal callback;

    constructor(string memory _callback) {
        callback = _callback;
    }

    function checkAfterTransaction(
        address,
        bytes4,
        uint8,
        uint256,
        bytes memory,
        bytes memory returnData
    ) external override {
        require(
            keccak256(abi.encodePacked(abi.decode(returnData, (string))))
                == keccak256(abi.encodePacked(callback)),
            "Callback mismatch"
        );
    }
}

contract RevertAfterHook is IAfterTransaction {
    function checkAfterTransaction(address, bytes4, uint8, uint256, bytes memory, bytes memory)
        external
        override
    {
        revert("RevertAfterHook");
    }
}

contract TestTradingModule is Test, TestBaseGnosis, TestBaseProtocol {
    using SafeUtils for SafeL2;

    address internal fundAdmin;
    uint256 internal fundAdminPK;
    SafeL2 internal fund;
    HookRegistry internal hookRegistry;
    TradingModule internal tradingModule;
    MockTarget internal target;
    address internal revertBeforeHook;
    address internal revertAfterHook;

    address internal operator;

    function setUp() public override(TestBaseGnosis, TestBaseProtocol) {
        TestBaseGnosis.setUp();
        TestBaseProtocol.setUp();

        operator = makeAddr("Operator");

        (fundAdmin, fundAdminPK) = makeAddrAndKey("FundAdmin");
        vm.deal(fundAdmin, 1000 ether);

        address[] memory admins = new address[](1);
        admins[0] = fundAdmin;

        fund = deploySafe(admins, 1);
        assertTrue(address(fund) != address(0), "Failed to deploy fund");
        assertTrue(fund.isOwner(fundAdmin), "Fund admin not owner");

        vm.deal(address(fund), 1000 ether);

        hookRegistry = HookRegistry(
            deployContract(
                payable(address(fund)),
                fundAdmin,
                fundAdminPK,
                bytes32("hookRegistry"),
                0,
                abi.encodePacked(type(HookRegistry).creationCode, abi.encode(address(fund)))
            )
        );

        vm.label(address(hookRegistry), "HookRegistry");

        tradingModule = TradingModule(
            deployModule(
                payable(address(fund)),
                fundAdmin,
                fundAdminPK,
                bytes32("tradingModule"),
                0,
                abi.encodePacked(
                    type(TradingModule).creationCode,
                    abi.encode(address(fund), address(hookRegistry))
                )
            )
        );
        vm.label(address(tradingModule), "TradingModule");

        assertEq(tradingModule.fund(), address(fund), "TradingModule fund not set");

        target = new MockTarget();
        vm.label(address(target), "MockTarget");

        revertBeforeHook = address(new RevertBeforeHook());
        vm.label(revertBeforeHook, "RevertBeforeHook");

        revertAfterHook = address(new RevertAfterHook());
        vm.label(revertAfterHook, "RevertAfterHook");

        // have to set gasprice > 0 so that gas refund is calculated
        vm.txGasPrice(100);
        vm.fee(99);
    }

    modifier withHook(HookConfig memory config) {
        vm.prank(address(fund));
        hookRegistry.setHooks(config);
        _;
    }

    function mock_hook() private view returns (HookConfig memory) {
        return HookConfig({
            operator: operator,
            target: address(target),
            beforeTrxHook: address(0),
            afterTrxHook: address(0),
            targetSelector: bytes4(keccak256("increment(uint256)")),
            operation: uint8(Enum.Operation.Call)
        });
    }

    function mock_trigger_revert_hook() private view returns (HookConfig memory config) {
        config = mock_hook();
        config.targetSelector = bytes4(keccak256("triggerRevert()"));
    }

    function mock_revert_before_hook() private view returns (HookConfig memory config) {
        config = mock_hook();
        config.beforeTrxHook = revertBeforeHook;
    }

    function mock_revert_after_hook() private view returns (HookConfig memory config) {
        config = mock_hook();
        config.afterTrxHook = revertAfterHook;
    }

    function mock_custom_hook() private returns (HookConfig memory config) {
        config = mock_hook();
        config.targetSelector = bytes4(keccak256("emitMessage(string)"));

        address beforeHook = address(new VerifyValueHook());
        address afterHook = address(new VerifyCallbackHook("hello world"));

        config.beforeTrxHook = beforeHook;
        config.afterTrxHook = afterHook;
    }

    function incrementCall(uint256 _value) private view returns (Transaction memory trx) {
        trx = Transaction({
            operation: uint8(Enum.Operation.Call),
            target: address(target),
            value: 0,
            data: abi.encode(_value),
            targetSelector: MockTarget.increment.selector
        });
    }

    function triggerRevertCall() private view returns (Transaction memory trx) {
        trx = Transaction({
            target: address(target),
            value: 0,
            operation: uint8(Enum.Operation.Call),
            targetSelector: MockTarget.triggerRevert.selector,
            data: bytes("")
        });
    }

    function emitMessageCall(string memory message, uint256 value)
        private
        view
        returns (Transaction memory trx)
    {
        trx = Transaction({
            target: address(target),
            value: value,
            operation: uint8(Enum.Operation.Call),
            targetSelector: MockTarget.emitMessage.selector,
            data: abi.encode(message)
        });
    }

    function test_execute() public withHook(mock_hook()) {
        Transaction[] memory calls = new Transaction[](4);
        calls[0] = incrementCall(10);
        calls[1] = incrementCall(20);
        calls[2] = incrementCall(0);
        calls[3] = incrementCall(500);

        uint256 adjustedFundBalance = address(fund).balance - 530;

        vm.prank(operator);
        tradingModule.execute(calls);

        assertEq(target.value(), 530, "Target value not incremented");
        assertTrue(adjustedFundBalance > address(fund).balance, "gas was not refunded");
    }

    function test_execute_reverts_if_gas_price_exceeds_limit() public withHook(mock_hook()) {
        vm.prank(address(fund));
        tradingModule.setMaxGasPriorityInBasisPoints(500);

        vm.txGasPrice(1000);

        Transaction[] memory calls = new Transaction[](1);
        calls[0] = incrementCall(10);

        vm.expectRevert(Errors.GasLimitExceeded.selector);
        vm.prank(operator);
        tradingModule.execute(calls);
    }

    function test_execute_reverts() public withHook(mock_trigger_revert_hook()) {
        vm.expectRevert("MockTarget revert");

        Transaction[] memory calls = new Transaction[](1);
        calls[0] = triggerRevertCall();

        vm.prank(operator);
        tradingModule.execute(calls);
    }

    function test_execute_with_full_hooks() public withHook(mock_custom_hook()) {
        Transaction[] memory calls = new Transaction[](1);
        calls[0] = emitMessageCall("hello world", 10);

        vm.prank(operator);
        tradingModule.execute(calls);
    }

    function test_only_operator_can_execute(address attacker) public withHook(mock_hook()) {
        vm.assume(attacker != operator);

        Transaction[] memory calls = new Transaction[](1);
        calls[0] = incrementCall(10);

        vm.expectRevert(Errors.HookNotDefined.selector);
        vm.prank(attacker);
        tradingModule.execute(calls);
    }

    function test_revert_before_hook() public withHook(mock_revert_before_hook()) {
        Transaction[] memory calls = new Transaction[](1);
        calls[0] = incrementCall(10);

        vm.expectRevert("RevertBeforeHook");
        vm.prank(operator);
        tradingModule.execute(calls);
    }

    function test_revert_after_hook() public withHook(mock_revert_after_hook()) {
        Transaction[] memory calls = new Transaction[](1);
        calls[0] = incrementCall(10);

        vm.expectRevert("RevertAfterHook");
        vm.prank(operator);
        tradingModule.execute(calls);
    }
}
