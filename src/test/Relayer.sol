// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";

import {IL2ToL2CrossDomainMessenger, Identifier} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ICrossL2Inbox} from "../interfaces/ICrossL2Inbox.sol";
import {IMessageRelayer} from "../interfaces/IMessageRelayer.sol";
import {IPromise} from "../interfaces/IPromise.sol";

import {PredeployAddresses} from "../libraries/PredeployAddresses.sol";
import {CrossDomainMessageLib} from "../libraries/CrossDomainMessageLib.sol";

/**
 * @title Relayer
 * @notice Abstract contract that simulates cross-chain message relaying between L2 chains
 * @dev This contract is designed for testing cross-chain messaging in a local environment
 *      by creating forks of two L2 chains and relaying messages between them.
 *      It captures SentMessage events using vm.recordLogs() and vm.getRecordedLogs() and relays them to their destination chains.
 */
abstract contract Relayer is CommonBase {
    struct RelayedMessage {
        Identifier id;
        bytes payload;
    }

    /// @notice Reference to the L2ToL2CrossDomainMessenger contract
    IL2ToL2CrossDomainMessenger messenger =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice Reference to the CrossL2Inbox contract
    ICrossL2Inbox crossL2Inbox = ICrossL2Inbox(PredeployAddresses.CROSS_L2_INBOX);

    /// @notice Array of fork IDs
    uint256[] public forkIds;

    /// @notice Mapping from chain ID to fork ID
    mapping(uint256 => uint256) public forkIdByChainId;

    /// @notice Mapping from fork ID to chain ID
    mapping(uint256 => uint256) public chainIdByForkId;

    /**
     * @notice Constructor that sets up the test environment with two chain forks
     * @dev Creates forks for two L2 chains and maps their chain IDs to fork IDs
     * @param _chainRpcs RPC URLs for the chains
     */
    constructor(string[] memory _chainRpcs) {
        vm.recordLogs();

        for (uint256 i = 0; i < _chainRpcs.length; i++) {
            uint256 forkId = vm.createSelectFork(_chainRpcs[i]);
            forkIds.push(forkId);
            forkIdByChainId[block.chainid] = forkId;
            chainIdByForkId[forkId] = block.chainid;
        }
    }

    /**
     * @notice Selects a fork based on the chain ID
     * @param chainId The chain ID to select
     * @return forkId The selected fork ID
     */
    function selectForkByChainId(uint256 chainId) internal returns (uint256) {
        uint256 forkId = forkIdByChainId[chainId];
        vm.selectFork(forkId);
        return forkId;
    }

    /**
     * @notice Relays all pending cross-chain messages using L2ToL2CrossDomainMessenger.
     */
    function relayAllMessages() public returns (RelayedMessage[] memory messages_) {
        messages_ = relayMessages(vm.getRecordedLogs(), chainIdByForkId[vm.activeFork()]);
    }

    /**
     * @notice Relays all pending cross-chain messages using a custom message relayer.
     */
    function relayAllMessagesWith(address messageRelayer) public returns (RelayedMessage[] memory messages_) {
        messages_ = relayMessagesWith(messageRelayer, vm.getRecordedLogs(), chainIdByForkId[vm.activeFork()]);
    }

    /**
     * @notice Relays a subset of the total logs using L2ToL2CrossDomainMessenger.
     */
    function relayMessages(Vm.Log[] memory logs, uint256 sourceChainId)
        public
        returns (RelayedMessage[] memory messages_)
    {
        messages_ = _relayMessages(address(messenger), logs, sourceChainId);
    }

    /**
     * @notice Relays a subset of the total logs using a custom message relayer.
     */
    function relayMessagesWith(address messageRelayer, Vm.Log[] memory logs, uint256 sourceChainId)
        public
        returns (RelayedMessage[] memory messages_)
    {
        messages_ = _relayMessages(messageRelayer, logs, sourceChainId);
    }

    /**
     * @notice Relays a set of logs with a custom message relayer.
     * @dev All messages must have the same source chain.
     * @dev Filters logs for SentMessage events and relays them to their destination chains
     *      This function handles the entire relay process:
     *      1. Captures all SentMessage events
     *      2. Constructs the message payload for each event
     *      3. Creates an Identifier for each message
     *      4. Selects the destination chain fork
     *      5. Relays the message to the destination
     * @param messageRelayer The address of the message relayer to use
     * @param logs The set of logs to relay
     * @param sourceChainId The chain ID where the messages originated
     * @return messages_ Array of RelayedMessage structs containing the message IDs and payloads that were processed
     */
    function _relayMessages(address messageRelayer, Vm.Log[] memory logs, uint256 sourceChainId)
        internal
        returns (RelayedMessage[] memory messages_)
    {
        uint256 originalFork = vm.activeFork();

        messages_ = new RelayedMessage[](logs.length);
        uint256 messageCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            // Skip logs that aren't SentMessage events
            if (log.topics[0] != keccak256("SentMessage(uint256,address,uint256,address,bytes)")) continue;

            // Get message destination chain id and select fork
            uint256 destination = uint256(log.topics[1]);
            selectForkByChainId(destination);

            // Spoof the block number, log index, and timestamp on the identifier because the
            // recorded log does not capture the block that the log was emitted on.
            Identifier memory id = Identifier(log.emitter, block.number, i, block.timestamp, sourceChainId);
            bytes memory payload = constructMessagePayload(log);

            // Build access list
            bytes32[] memory storageKeys = new bytes32[](2);
            // Storage key 0: idPacked
            storageKeys[0] = CrossDomainMessageLib.packIdentifier(id);
            // Storage key 1: checksum
            storageKeys[1] = CrossDomainMessageLib.calculateChecksum(id, keccak256(payload));
            VmSafe.AccessListItem[] memory accessList = new VmSafe.AccessListItem[](1);
            accessList[0] = VmSafe.AccessListItem({target: address(crossL2Inbox), storageKeys: storageKeys});

            // Relay message
            vm.accessList(accessList);
            IMessageRelayer(messageRelayer).relayMessage(id, payload);

            // Add to messages array (using index assignment instead of push)
            messages_[messageCount] = RelayedMessage({id: id, payload: payload});
            messageCount++;
        }

        // If we didn't use all allocated slots, create a properly sized array
        if (messageCount < logs.length) {
            // Create a new array of the correct size
            RelayedMessage[] memory resizedMessages = new RelayedMessage[](messageCount);
            for (uint256 i = 0; i < messageCount; i++) {
                resizedMessages[i] = messages_[i];
            }
            messages_ = resizedMessages;
        }

        vm.selectFork(originalFork);
    }

    /**
     * @notice Relays all promise callbacks for messages received on the source chain
     * @dev Filters logs for RelayedMessage events and dispatches their callbacks through the Promise contract
     *      This function handles the promise callback relay process:
     *      1. Selects the source chain fork
     *      2. Gets all recorded logs
     *      3. Filters for RelayedMessage events
     *      4. Constructs message payload and identifier
     *      5. Dispatches callbacks through the Promise contract
     * @param p The Promise contract instance to dispatch callbacks through
     * @param sourceChainId The chain ID where the messages originated
     * @return messages_ Array of RelayedMessage structs containing the message IDs and payloads that were processed
     */
    function relayAllPromises(IPromise p, uint256 sourceChainId) public returns (RelayedMessage[] memory messages_) {
        messages_ = relayPromises(vm.getRecordedLogs(), p, sourceChainId);
    }

    /**
     * Use this instead of relayAllPromises if you want to relay a subset of logs and need to have control over when
     * vm.getRecordedLogs() is called.
     */
    function relayPromises(Vm.Log[] memory logs, IPromise p, uint256 sourceChainId)
        public
        returns (RelayedMessage[] memory messages_)
    {
        vm.selectFork(selectForkByChainId(sourceChainId));

        messages_ = new RelayedMessage[](logs.length);
        uint256 messageCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.topics[0] != keccak256("RelayedMessage(bytes32,bytes)")) continue;

            bytes memory payload = constructMessagePayload(log);
            Identifier memory id = Identifier(log.emitter, block.number, 0, block.timestamp, sourceChainId);

            // Build access list
            bytes32[] memory storageKeys = new bytes32[](2);
            // Storage key 0: idPacked
            storageKeys[0] = CrossDomainMessageLib.packIdentifier(id);
            // Storage key 1: checksum
            storageKeys[1] = CrossDomainMessageLib.calculateChecksum(id, keccak256(payload));
            VmSafe.AccessListItem[] memory accessList = new VmSafe.AccessListItem[](1);
            accessList[0] = VmSafe.AccessListItem({target: address(crossL2Inbox), storageKeys: storageKeys});

            vm.accessList(accessList);
            p.dispatchCallbacks(id, payload);

            // Add to messages array (using index assignment instead of push)
            messages_[messageCount] = RelayedMessage({id: id, payload: payload});
            messageCount++;
        }

        // If we didn't use all allocated slots, create a properly sized array
        if (messageCount < logs.length) {
            // Create a new array of the correct size
            RelayedMessage[] memory resizedMessages = new RelayedMessage[](messageCount);
            for (uint256 i = 0; i < messageCount; i++) {
                resizedMessages[i] = messages_[i];
            }
            messages_ = resizedMessages;
        }
    }

    /**
     * @notice Constructs a message payload from a log using pure Solidity
     * @param log The log containing the SentMessage event data
     * @return A bytes array containing the reconstructed message payload
     */
    function constructMessagePayload(Vm.Log memory log) internal pure returns (bytes memory) {
        bytes memory payload = new bytes(0);

        // Append each topic (32 bytes each)
        for (uint256 i = 0; i < log.topics.length; i++) {
            payload = abi.encodePacked(payload, log.topics[i]);
        }

        // Append the data
        payload = abi.encodePacked(payload, log.data);

        return payload;
    }
}
