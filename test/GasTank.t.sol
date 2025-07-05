// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/Console.sol";

import {Relayer} from "../src/test/Relayer.sol";
import {ICreate2Deployer} from "../src/interfaces/ICreate2Deployer.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";
import {IGasTank, GasTank} from "../src/experiment/GasTank.sol";
import {MessageSender} from "../src/experiment/MessageSender.sol";
import {Identifier} from "../src/interfaces/IIdentifier.sol";
import {IL2ToL2CrossDomainMessenger} from "../src/interfaces/IL2ToL2CrossDomainMessenger.sol";

contract GasTankTest is StdUtils, Test, Relayer {
    GasTank public gasTank901;
    GasTank public gasTank902;
    MessageSender public messageSender901;
    MessageSender public messageSender902;

    address public gasProvider;
    address public user;
    address public relayer;

    uint256 public chainA;
    uint256 public chainB;

    // Run against supersim locally so forking is fast
    string[] public rpcUrls = ["http://127.0.0.1:9545", "http://127.0.0.1:9546"];

    constructor() Relayer(rpcUrls) {
        chainA = forkIds[0];
        chainB = forkIds[1];
    }

    function setUp() public virtual {
        bytes32 salt = bytes32(block.timestamp);

        // Set up accounts (using hardcoded private keys from Supersim)
        gasProvider = vm.addr(uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        user = vm.addr(uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d));
        relayer = vm.addr(uint256(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a));

        // Deploy GasTank contracts on both chains
        vm.selectFork(chainA);
        gasTank901 = new GasTank{salt: salt}();
        messageSender901 = new MessageSender{salt: salt}();
        vm.deal(gasProvider, 100 ether);

        vm.selectFork(chainB);
        gasTank902 = new GasTank{salt: salt}();
        messageSender902 = new MessageSender{salt: salt}();
        vm.deal(gasProvider, 100 ether);
    }

    /// forge-config: default.isolate = true
    function test_gasTankRelay() public {
        vm.selectFork(chainA);

        /// 1. User sends the cross chain message
        bytes32[] memory messageHashes = new bytes32[](1);
        // Encode msg to be executed on the destination chain (902): MessageSender.sendMessages(chainA, 10)
        // chainA == origin chain
        bytes memory message = abi.encodeCall(MessageSender.sendMessages, (chainA, uint256(10)));
        uint256 _nonce = messenger.messageNonce();

        vm.expectEmit();
        emit IL2ToL2CrossDomainMessenger.SentMessage(
            chainIdByForkId[chainB], address(messageSender902), _nonce, user, message
        );
        vm.prank(user);
        messageHashes[0] = messenger.sendMessage(chainIdByForkId[chainB], address(messageSender902), message);

        // 2. User authorizes to claim reimbursement for this message on the origin chain
        vm.expectEmit(address(gasTank901));
        emit IGasTank.AuthorizedClaims(user, messageHashes);
        vm.prank(user);
        gasTank901.authorizeClaim(messageHashes[0]);
        assertTrue(gasTank901.authorizedMessages(user, messageHashes[0]));

        // 3. Fund the GasTank up to the maximum deposit for the deployer/gas provider account
        uint256 currentBalance = gasTank901.balanceOf(gasProvider);
        uint256 maxDeposit = gasTank901.MAX_DEPOSIT();

        if (currentBalance < maxDeposit) {
            uint256 amountToDeposit = maxDeposit - currentBalance;
            vm.expectEmit(address(gasTank901));
            emit IGasTank.Deposit(gasProvider, amountToDeposit);
            vm.prank(gasProvider);
            gasTank901.deposit{value: amountToDeposit}(gasProvider);
        }

        // 4. Relayer relays the message
        vm.selectFork(chainB);
        // Only relay the message that was sent on chainB
        VmSafe.Log[] memory logs = new VmSafe.Log[](1);
        bytes32[] memory topics = new bytes32[](4);
        topics[0] = bytes32(abi.encode(IL2ToL2CrossDomainMessenger.SentMessage.selector));
        topics[1] = bytes32(chainIdByForkId[chainB]);
        topics[2] = bytes32(uint256(uint160(address(messageSender902))));
        topics[3] = bytes32(_nonce);

        logs[0] = VmSafe.Log({topics: topics, data: abi.encode(user, message), emitter: address(messenger)});

        vm.prank(relayer);
        // vm.expectEmit(address(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER));
        // emit IL2ToL2CrossDomainMessenger.RelayedMessage(
        //     chainIdByForkId[chainA], _nonce, messageHashes[0], keccak256("")
        // );
        relayMessagesWith(address(gasTank902), logs, chainIdByForkId[chainA]);
    }
}
