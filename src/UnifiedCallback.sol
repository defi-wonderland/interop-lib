// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "./Promise.sol";
import {IResolvable} from "./interfaces/IResolvable.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";

/// @title UnifiedCallback
/// @notice Unified callback contract that handles Promise-based callbacks with optional CDM verification
/// @dev Supports .then(), .catchError() with optional CDM message success verification
contract UnifiedCallback is IResolvable {
    /// @notice The Promise contract instance
    Promise public immutable promiseContract;

    /// @notice Cross-domain messenger for CDM callbacks and cross-chain operations
    IL2ToL2CrossDomainMessenger public immutable messenger;

    /// @notice Current chain ID for generating global promise IDs
    uint256 public immutable currentChainId;

    /// @notice Default callback registrant when no callback is being executed
    address internal constant DEFAULT_CALLBACK_REGISTRANT = address(0);

    /// @notice Current callback context - who registered the currently executing callback
    address internal currentCallbackRegistrant;

    /// @notice Current callback context - which chain the currently executing callback was registered from
    uint256 internal currentCallbackSourceChain;

    /// @notice Trigger types for different callback execution conditions
    enum TriggerType {
        PromiseThen, // Execute when parent promise resolves (with optional CDM verification)
        PromiseCatch // Execute when parent promise rejects (with optional CDM verification)

    }

    /// @notice Unified callback data structure
    struct UnifiedCallbackData {
        TriggerType triggerType;
        address target;
        bytes4 selector;
        address registrant;
        uint256 sourceChain;
        // Promise-specific fields
        bytes32 parentPromiseId;
        // CDM-specific fields
        bytes32[] messageHashes; // For both CDMSingle and CDMMulti
    }

    /// @notice Mapping from callback promise ID to callback data
    mapping(bytes32 => UnifiedCallbackData) public callbacks;

    /// @notice Event emitted when a callback is registered
    event CallbackRegistered(
        bytes32 indexed callbackPromiseId, bytes32 indexed parentPromiseId, TriggerType triggerType
    );

    /// @notice Event emitted when a callback is executed
    event CallbackExecuted(bytes32 indexed callbackPromiseId, bool success, bytes returnData);

    /// @param _promiseContract The address of the Promise contract
    /// @param _messenger The cross-domain messenger contract address (use address(0) for CDM-disabled mode)
    constructor(address _promiseContract, address _messenger) {
        require(_promiseContract != address(0), "UnifiedCallback: invalid promise contract");

        promiseContract = Promise(_promiseContract);
        messenger = IL2ToL2CrossDomainMessenger(_messenger);
        currentChainId = block.chainid;
    }

    /// @notice Create a .then() callback that executes when the parent promise resolves
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call when parent resolves
    /// @param selector The function selector to call
    /// @return callbackPromiseId The ID of the created callback promise
    function then(bytes32 parentPromiseId, address target, bytes4 selector)
        external
        returns (bytes32 callbackPromiseId)
    {
        callbackPromiseId = promiseContract.create();

        callbacks[callbackPromiseId] = UnifiedCallbackData({
            triggerType: TriggerType.PromiseThen,
            target: target,
            selector: selector,
            registrant: msg.sender,
            sourceChain: currentChainId,
            parentPromiseId: parentPromiseId,
            messageHashes: new bytes32[](0)
        });

        emit CallbackRegistered(callbackPromiseId, parentPromiseId, TriggerType.PromiseThen);
    }

    /// @notice Create a .catchError() callback that executes when the parent promise rejects
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call when parent rejects
    /// @param selector The function selector to call
    /// @return callbackPromiseId The ID of the created callback promise
    function catchError(bytes32 parentPromiseId, address target, bytes4 selector)
        external
        returns (bytes32 callbackPromiseId)
    {
        callbackPromiseId = promiseContract.create();

        callbacks[callbackPromiseId] = UnifiedCallbackData({
            triggerType: TriggerType.PromiseCatch,
            target: target,
            selector: selector,
            registrant: msg.sender,
            sourceChain: currentChainId,
            parentPromiseId: parentPromiseId,
            messageHashes: new bytes32[](0)
        });

        emit CallbackRegistered(callbackPromiseId, parentPromiseId, TriggerType.PromiseCatch);
    }

    /// @notice Create a cross-chain .then() callback that executes on another chain when the parent promise resolves
    /// @param destinationChain The chain ID where the callback should execute
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call when parent resolves
    /// @param selector The function selector to call
    /// @return callbackPromiseId The ID of the created callback promise
    function thenOn(uint256 destinationChain, bytes32 parentPromiseId, address target, bytes4 selector)
        external
        returns (bytes32 callbackPromiseId)
    {
        return _createCrossChainCallback(
            destinationChain, parentPromiseId, target, selector, TriggerType.PromiseThen, new bytes32[](0)
        );
    }

    /// @notice Create a cross-chain .then() callback with CDM verification that executes when parent promise resolves AND CDM messages succeed
    /// @param destinationChain The chain ID where the callback should execute
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call when conditions are met
    /// @param selector The function selector to call
    /// @param cdmMessageHashes Array of CDM message hashes that must be successful
    /// @return callbackPromiseId The ID of the created callback promise
    function thenOnWithCDM(
        uint256 destinationChain,
        bytes32 parentPromiseId,
        address target,
        bytes4 selector,
        bytes32[] calldata cdmMessageHashes
    ) external returns (bytes32 callbackPromiseId) {
        require(cdmMessageHashes.length > 0, "UnifiedCallback: CDM message hashes required");
        for (uint256 i = 0; i < cdmMessageHashes.length; i++) {
            require(cdmMessageHashes[i] != bytes32(0), "UnifiedCallback: invalid CDM message hash");
        }
        return _createCrossChainCallback(
            destinationChain, parentPromiseId, target, selector, TriggerType.PromiseThen, cdmMessageHashes
        );
    }

    /// @notice Internal function to create cross-chain callbacks with optional CDM verification
    /// @param destinationChain The chain ID where the callback should execute
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call
    /// @param selector The function selector to call
    /// @param triggerType The type of callback (PromiseThen or PromiseCatch)
    /// @param cdmMessageHashes Array of CDM message hashes to verify (empty array for no CDM verification)
    /// @return callbackPromiseId The ID of the created callback promise
    function _createCrossChainCallback(
        uint256 destinationChain,
        bytes32 parentPromiseId,
        address target,
        bytes4 selector,
        TriggerType triggerType,
        bytes32[] memory cdmMessageHashes
    ) internal returns (bytes32 callbackPromiseId) {
        require(address(messenger) != address(0), "UnifiedCallback: cross-chain not enabled");
        // require(destinationChain != currentChainId, "UnifiedCallback: cannot register callback on same chain");
        require(
            triggerType == TriggerType.PromiseThen || triggerType == TriggerType.PromiseCatch,
            "UnifiedCallback: invalid trigger type for cross-chain"
        );

        callbackPromiseId = promiseContract.create();

        promiseContract.transferResolve(callbackPromiseId, destinationChain, address(this));

        bytes memory message = abi.encodeWithSignature(
            "receiveCallbackRegistration(bytes32,uint8,bytes32,address,bytes4,address,uint256,bytes32[])",
            callbackPromiseId,
            uint8(triggerType),
            parentPromiseId,
            target,
            selector,
            msg.sender,
            currentChainId,
            cdmMessageHashes
        );

        messenger.sendMessage(destinationChain, address(this), message);

        emit CallbackRegistered(callbackPromiseId, parentPromiseId, triggerType);
    }

    /// @notice Create a cross-chain .catchError() callback that executes on another chain when the parent promise rejects
    /// @param destinationChain The chain ID where the callback should execute
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call when parent rejects
    /// @param selector The function selector to call
    /// @return callbackPromiseId The ID of the created callback promise
    function catchErrorOn(uint256 destinationChain, bytes32 parentPromiseId, address target, bytes4 selector)
        external
        returns (bytes32 callbackPromiseId)
    {
        return _createCrossChainCallback(
            destinationChain, parentPromiseId, target, selector, TriggerType.PromiseCatch, new bytes32[](0)
        );
    }

    /// @notice Create a cross-chain .catchError() callback with CDM verification that executes when parent promise rejects AND CDM messages succeed
    /// @param destinationChain The chain ID where the callback should execute
    /// @param parentPromiseId The ID of the parent promise to watch
    /// @param target The contract address to call when conditions are met
    /// @param selector The function selector to call
    /// @param cdmMessageHashes Array of CDM message hashes that must be successful
    /// @return callbackPromiseId The ID of the created callback promise
    function catchErrorOnWithCDM(
        uint256 destinationChain,
        bytes32 parentPromiseId,
        address target,
        bytes4 selector,
        bytes32[] calldata cdmMessageHashes
    ) external returns (bytes32 callbackPromiseId) {
        require(cdmMessageHashes.length > 0, "UnifiedCallback: CDM message hashes required");
        for (uint256 i = 0; i < cdmMessageHashes.length; i++) {
            require(cdmMessageHashes[i] != bytes32(0), "UnifiedCallback: invalid CDM message hash");
        }
        return _createCrossChainCallback(
            destinationChain, parentPromiseId, target, selector, TriggerType.PromiseCatch, cdmMessageHashes
        );
    }

    /// @notice Receive callback registration from another chain (with optional CDM verification)
    /// @param callbackPromiseId The global callback promise ID
    /// @param triggerType The type of trigger (PromiseThen or PromiseCatch)
    /// @param parentPromiseId The parent promise ID to watch
    /// @param target The contract address to call when parent settles
    /// @param selector The function selector to call
    /// @param registrant The original address that registered this callback
    /// @param sourceChain The chain ID where this callback was originally registered
    /// @param cdmMessageHashes Array of CDM message hashes that must be successful (empty for no CDM verification)
    function receiveCallbackRegistration(
        bytes32 callbackPromiseId,
        uint8 triggerType,
        bytes32 parentPromiseId,
        address target,
        bytes4 selector,
        address registrant,
        uint256 sourceChain,
        bytes32[] calldata cdmMessageHashes
    ) external {
        require(address(messenger) != address(0), "UnifiedCallback: cross-chain not enabled");
        require(msg.sender == address(messenger), "UnifiedCallback: only messenger can call");
        require(
            messenger.crossDomainMessageSender() == address(this), "UnifiedCallback: only from UnifiedCallback contract"
        );
        require(triggerType <= uint8(TriggerType.PromiseCatch), "UnifiedCallback: invalid trigger type for cross-chain");

        callbacks[callbackPromiseId] = UnifiedCallbackData({
            triggerType: TriggerType(triggerType),
            target: target,
            selector: selector,
            registrant: registrant,
            sourceChain: sourceChain,
            parentPromiseId: parentPromiseId,
            messageHashes: cdmMessageHashes
        });

        emit CallbackRegistered(callbackPromiseId, parentPromiseId, TriggerType(triggerType));
    }

    /// @notice Get the registrant of the currently executing callback
    /// @dev Will revert if no callback is currently being executed
    /// @return The address that registered the currently executing callback
    function callbackRegistrant() external view returns (address) {
        require(
            currentCallbackRegistrant != DEFAULT_CALLBACK_REGISTRANT, "UnifiedCallback: no callback currently executing"
        );
        return currentCallbackRegistrant;
    }

    /// @notice Get the source chain of the currently executing callback
    /// @dev Will revert if no callback is currently being executed
    /// @return The chain ID where the currently executing callback was registered
    function callbackSourceChain() external view returns (uint256) {
        require(
            currentCallbackRegistrant != DEFAULT_CALLBACK_REGISTRANT, "UnifiedCallback: no callback currently executing"
        );
        return currentCallbackSourceChain;
    }

    /// @notice Get the full context of the currently executing callback
    /// @dev Will revert if no callback is currently being executed
    /// @return registrant The address that registered the currently executing callback
    /// @return sourceChain The chain ID where the currently executing callback was registered
    function callbackContext() external view returns (address registrant, uint256 sourceChain) {
        require(
            currentCallbackRegistrant != DEFAULT_CALLBACK_REGISTRANT, "UnifiedCallback: no callback currently executing"
        );
        return (currentCallbackRegistrant, currentCallbackSourceChain);
    }

    /// @notice Resolve a callback promise by executing the callback if trigger conditions are met
    /// @param callbackPromiseId The ID of the callback promise to resolve
    function resolve(bytes32 callbackPromiseId) external {
        UnifiedCallbackData memory callbackData = callbacks[callbackPromiseId];
        require(callbackData.target != address(0), "UnifiedCallback: callback does not exist");

        Promise.PromiseStatus callbackStatus = promiseContract.status(callbackPromiseId);
        require(callbackStatus == Promise.PromiseStatus.Pending, "UnifiedCallback: callback already settled");

        bool shouldExecute = false;
        bytes memory callData;

        if (callbackData.triggerType == TriggerType.PromiseThen || callbackData.triggerType == TriggerType.PromiseCatch)
        {
            // Handle promise-based callbacks (with optional CDM verification)
            Promise.PromiseData memory parentPromise = promiseContract.getPromise(callbackData.parentPromiseId);

            if (
                callbackData.triggerType == TriggerType.PromiseThen
                    && parentPromise.status == Promise.PromiseStatus.Resolved
            ) {
                shouldExecute = true;
                callData = abi.encodeWithSelector(callbackData.selector, parentPromise.returnData);
            } else if (
                callbackData.triggerType == TriggerType.PromiseCatch
                    && parentPromise.status == Promise.PromiseStatus.Rejected
            ) {
                shouldExecute = true;
                callData = abi.encodeWithSelector(callbackData.selector, parentPromise.returnData);
            } else if (parentPromise.status == Promise.PromiseStatus.Pending) {
                revert("UnifiedCallback: parent promise not settled");
            } else {
                // Parent is settled but doesn't match callback type, reject this callback
                promiseContract.reject(callbackPromiseId, abi.encode("Callback not applicable"));
                delete callbacks[callbackPromiseId];
                emit CallbackExecuted(callbackPromiseId, false, abi.encode("Callback not applicable"));
                return;
            }

            // If CDM verification is required, check all message hashes
            if (callbackData.messageHashes.length > 0) {
                require(address(messenger) != address(0), "UnifiedCallback: CDM not enabled");
                for (uint256 i = 0; i < callbackData.messageHashes.length; i++) {
                    require(
                        messenger.successfulMessages(callbackData.messageHashes[i]),
                        "UnifiedCallback: CDM message(s) not yet successful"
                    );
                }
            }
        }

        require(shouldExecute, "UnifiedCallback: trigger conditions not met");

        // Re-entrancy protection
        require(currentCallbackRegistrant == DEFAULT_CALLBACK_REGISTRANT, "UnifiedCallback: re-entrant call detected");

        // Set callback context before execution
        currentCallbackRegistrant = callbackData.registrant;
        currentCallbackSourceChain = callbackData.sourceChain;

        // Execute the callback
        (bool success, bytes memory returnData) = callbackData.target.call(callData);

        // Clear callback context after execution
        currentCallbackRegistrant = DEFAULT_CALLBACK_REGISTRANT;
        currentCallbackSourceChain = 0;

        if (success) {
            promiseContract.resolve(callbackPromiseId, returnData);
        } else {
            promiseContract.reject(callbackPromiseId, returnData);
        }

        // Clean up storage
        delete callbacks[callbackPromiseId];

        emit CallbackExecuted(callbackPromiseId, success, returnData);
    }

    /// @notice Check if a callback can be resolved
    /// @param callbackPromiseId The ID of the callback promise to check
    /// @return canResolveCallback Whether the callback can be resolved now
    function canResolve(bytes32 callbackPromiseId) external view returns (bool canResolveCallback) {
        UnifiedCallbackData memory callbackData = callbacks[callbackPromiseId];
        if (callbackData.target == address(0)) return false;

        Promise.PromiseStatus callbackStatus = promiseContract.status(callbackPromiseId);
        if (callbackStatus != Promise.PromiseStatus.Pending) return false;

        if (callbackData.triggerType == TriggerType.PromiseThen || callbackData.triggerType == TriggerType.PromiseCatch)
        {
            // Check promise-based callbacks (with optional CDM verification)
            Promise.PromiseData memory parentPromise = promiseContract.getPromise(callbackData.parentPromiseId);

            bool promiseConditionMet = false;
            if (
                callbackData.triggerType == TriggerType.PromiseThen
                    && parentPromise.status == Promise.PromiseStatus.Resolved
            ) {
                promiseConditionMet = true;
            } else if (
                callbackData.triggerType == TriggerType.PromiseCatch
                    && parentPromise.status == Promise.PromiseStatus.Rejected
            ) {
                promiseConditionMet = true;
            } else if (parentPromise.status != Promise.PromiseStatus.Pending) {
                return true; // Can resolve to reject the callback
            }

            if (promiseConditionMet) {
                // If CDM verification is required, check all message hashes
                if (callbackData.messageHashes.length > 0) {
                    if (address(messenger) == address(0)) return false;
                    for (uint256 i = 0; i < callbackData.messageHashes.length; i++) {
                        if (!messenger.successfulMessages(callbackData.messageHashes[i])) {
                            return false;
                        }
                    }
                }
                return true;
            }
        }

        return false;
    }

    /// @notice Get callback data for a callback promise
    /// @param callbackPromiseId The ID of the callback promise
    /// @return callbackData The callback data, or empty if doesn't exist
    function getCallback(bytes32 callbackPromiseId) external view returns (UnifiedCallbackData memory callbackData) {
        return callbacks[callbackPromiseId];
    }

    /// @notice Check if a callback promise exists
    /// @param callbackPromiseId The ID of the callback promise to check
    /// @return callbackExists Whether the callback exists
    function exists(bytes32 callbackPromiseId) external view returns (bool callbackExists) {
        return callbacks[callbackPromiseId].target != address(0);
    }
}
