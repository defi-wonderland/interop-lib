// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IResolvable} from "./interfaces/IResolvable.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";

/// @title PromiseCallback
/// @notice Pure promise system where everything is a promise
/// @dev Unified design eliminating artificial promise/callback distinction
contract PromiseCallback is IResolvable {
    /// @notice Promise states matching JavaScript promise semantics
    enum PromiseStatus {
        Pending,
        Resolved,
        Rejected
    }

    /// @notice Dependency types for promise resolution
    enum DependencyType {
        None, // No dependency - basic promise
        Then, // Resolves when parent resolves
        Catch // Resolves when parent rejects

    }

    /// @notice Unified promise data structure
    struct Promise {
        address resolver; // Who can manually resolve this promise
        PromiseStatus status; // Current state
        bytes returnData; // Resolution data
        // Dependency (optional)
        bytes32 parentPromiseId; // Parent promise (bytes32(0) for none)
        DependencyType dependencyType; // How this relates to parent
        // Auto-execution (optional)
        address target; // Contract to call when resolving (address(0) for manual)
        bytes executionData; // Selector (4 bytes) or full calldata (>4 bytes)
        // Context
        address creator; // Who created this promise
        uint256 sourceChain; // Origin chain
        IValidator validator; // Custom validation (optional)
        bytes validationData; // Validation parameters
    }

    /// @notice Promise counter for generating unique IDs
    uint256 private nonce;

    /// @notice Mapping from promise ID to promise data
    mapping(bytes32 => Promise) public promises;

    /// @notice Cross-domain messenger for cross-chain operations
    IL2ToL2CrossDomainMessenger public constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice Default execution registrant when no execution is happening
    address internal constant DEFAULT_EXECUTION_REGISTRANT = address(0);

    /// @notice Execution context tracking
    address internal currentExecutionContext;
    uint256 internal currentExecutionSourceChain;

    // =============================================================================
    // EVENTS
    // =============================================================================

    /// @notice Event emitted when a new promise is created
    event PromiseCreated(bytes32 indexed promiseId, address indexed resolver, address indexed creator);

    /// @notice Event emitted when a promise is resolved
    event PromiseResolved(bytes32 indexed promiseId, bytes returnData);

    /// @notice Event emitted when a promise is rejected
    event PromiseRejected(bytes32 indexed promiseId, bytes errorData);

    /// @notice Event emitted when a promise is executed (has target)
    event PromiseExecuted(bytes32 indexed promiseId, bool success, bytes returnData);

    /// @notice Event emitted when a resolved promise is shared to another chain
    event PromiseShared(bytes32 indexed promiseId, uint256 indexed destinationChain);

    // =============================================================================
    // CORE PROMISE FUNCTIONALITY
    // =============================================================================

    /// @notice Generate a global promise ID from chain ID and nonce
    /// @param nonceValue The nonce value
    /// @return globalPromiseId The globally unique promise ID
    function generateGlobalPromiseId(bytes32 nonceValue) public view returns (bytes32 globalPromiseId) {
        return keccak256(abi.encode(block.chainid, nonceValue));
    }

    /// @notice Create a promise with full control over all parameters
    /// @param resolver The address that can resolve this promise
    /// @param parentPromiseId The parent promise ID (bytes32(0) for none)
    /// @param dependencyType How this promise relates to its parent (0=None, 1=Then, 2=Catch)
    /// @param target The contract to call when resolving (address(0) for manual)
    /// @param executionData Selector (4 bytes) or full calldata (>4 bytes)
    /// @param validator Custom validator contract (address(0) for none)
    /// @param validationData Data for the validator
    /// @param destinationChain Chain where promise should be created (0 for current)
    /// @return promiseId The unique identifier for the new promise
    function create(
        address resolver,
        bytes32 parentPromiseId,
        DependencyType dependencyType,
        address target,
        bytes calldata executionData,
        IValidator validator,
        bytes calldata validationData,
        uint256 destinationChain
    ) external returns (bytes32 promiseId) {
        // Validate execution data if target is provided
        if (target != address(0)) {
            require(executionData.length >= 4, "PromiseCallback: execution data too short");
        }

        // Use current chain if not specified
        if (destinationChain == 0) {
            destinationChain = block.chainid;
        }

        return _createPromise({
            promiseId: bytes32(0),
            resolver: resolver,
            parentPromiseId: parentPromiseId,
            dependencyType: dependencyType,
            target: target,
            executionData: executionData,
            creator: msg.sender,
            sourceChain: block.chainid,
            validator: validator,
            validationData: validationData,
            destinationChain: destinationChain
        });
    }

    /// @notice Internal function to create a promise (handles cross-chain)
    /// @param promiseId The specific ID to use (bytes32(0) to auto-generate)
    /// @param resolver The address that can resolve this promise
    /// @param parentPromiseId The parent promise ID (bytes32(0) for none)
    /// @param dependencyType How this promise relates to its parent
    /// @param target The contract to call when resolving (address(0) for manual)
    /// @param executionData Selector (4 bytes) or full calldata (>4 bytes)
    /// @param creator Who created this promise
    /// @param sourceChain Origin chain ID
    /// @param validator Custom validator contract
    /// @param validationData Data for the validator
    /// @param destinationChain Chain where promise should be created (0 for current)
    /// @return promiseId The unique identifier for the new promise
    function _createPromise(
        bytes32 promiseId,
        address resolver,
        bytes32 parentPromiseId,
        DependencyType dependencyType,
        address target,
        bytes memory executionData,
        address creator,
        uint256 sourceChain,
        IValidator validator,
        bytes memory validationData,
        uint256 destinationChain
    ) internal returns (bytes32) {
        require(destinationChain != 0, "PromiseCallback: destination chain cannot be 0");

        // Generate ID if not specified
        if (promiseId == bytes32(0)) {
            uint256 currentNonce = nonce++;
            promiseId = generateGlobalPromiseId(bytes32(currentNonce));
        }

        // Add existence check before creating
        require(promises[promiseId].resolver == address(0), "PromiseCallback: promise already exists");

        // Handle cross-chain creation
        if (destinationChain != block.chainid) {
            bytes memory message = abi.encodeCall(
                this.receivePromiseCreation,
                (
                    promiseId,
                    resolver,
                    parentPromiseId,
                    uint8(dependencyType),
                    target,
                    executionData,
                    creator,
                    address(validator),
                    validationData
                )
            );

            MESSENGER.sendMessage(destinationChain, address(this), message);
            emit PromiseCreated(promiseId, resolver, creator);
            return promiseId;
        }

        // Create locally
        promises[promiseId] = Promise({
            resolver: resolver,
            status: PromiseStatus.Pending,
            returnData: "",
            parentPromiseId: parentPromiseId,
            dependencyType: dependencyType,
            target: target,
            executionData: executionData,
            creator: creator,
            sourceChain: sourceChain,
            validator: validator,
            validationData: validationData
        });

        emit PromiseCreated(promiseId, resolver, creator);
        return promiseId;
    }

    /// @notice Resolve any promise - unified resolution path
    /// @param promiseId The ID of the promise to resolve
    function resolve(bytes32 promiseId) external {
        require(canResolve(promiseId), "PromiseCallback: cannot resolve");

        Promise storage promiseData = promises[promiseId];

        if (promiseData.target != address(0)) {
            // Auto-execute target
            _executeTarget(promiseId);
        } else {
            // Manual resolution - only resolver can resolve without data
            require(msg.sender == promiseData.resolver, "PromiseCallback: only resolver can resolve");
            _resolvePromise(promiseId, "");
        }
    }

    /// @notice Manually resolve a promise with specific data
    /// @param promiseId The ID of the promise to resolve
    /// @param returnData The data to resolve the promise with
    function resolveWith(bytes32 promiseId, bytes calldata returnData) external {
        require(canResolve(promiseId), "PromiseCallback: cannot resolve");
        require(msg.sender == promises[promiseId].resolver, "PromiseCallback: only resolver can resolve");

        _resolvePromise(promiseId, returnData);
    }

    /// @notice Reject a promise with error data
    /// @param promiseId The ID of the promise to reject
    /// @param errorData The error data to reject the promise with
    function reject(bytes32 promiseId, bytes memory errorData) external {
        Promise storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "PromiseCallback: promise already settled");
        require(msg.sender == promiseData.resolver, "PromiseCallback: only resolver can reject");

        _rejectPromise(promiseId, errorData);
    }

    /// @notice Check if a promise can be resolved
    /// @param promiseId The ID of the promise to check
    /// @return canResolvePromise Whether the promise can be resolved now
    function canResolve(bytes32 promiseId) public view returns (bool canResolvePromise) {
        Promise memory promiseData = promises[promiseId];

        // Basic checks
        if (promiseData.resolver == address(0)) return false; // Promise doesn't exist
        if (promiseData.status != PromiseStatus.Pending) return false; // Already settled

        // Check dependency if any
        if (promiseData.parentPromiseId != bytes32(0)) {
            if (!_checkDependency(promiseData.parentPromiseId, promiseData.dependencyType)) {
                return false;
            }
        }

        // Check validator if specified
        if (address(promiseData.validator) != address(0)) {
            bytes memory validationData =
                _prepareValidationCallData(promiseData.validationData, promiseData.parentPromiseId);
            try promiseData.validator.canResolve(validationData) returns (bool validated) {
                return validated;
            } catch {
                return false; // Validator failed
            }
        }

        return true;
    }

    /// @notice Internal function to prepare validation call data
    /// @dev If validationData is empty and has parent promise, use parent return data
    /// @param validationData The validation data
    /// @param parentPromiseId The parent promise ID
    /// @return validationCallData The prepared validation call data
    function _prepareValidationCallData(bytes memory validationData, bytes32 parentPromiseId)
        internal
        view
        returns (bytes memory validationCallData)
    {
        if (validationData.length == 0 && parentPromiseId != bytes32(0)) {
            return promises[parentPromiseId].returnData;
        }
        return validationData;
    }

    /// @notice Internal function to prepare call data for promise execution
    /// @param executionData The execution data (selector or full calldata)
    /// @param parentPromiseId The parent promise ID (bytes32(0) if no parent)
    /// @return executeCallData The prepared call data for the target contract
    function _prepareExecutionCallData(bytes memory executionData, bytes32 parentPromiseId)
        internal
        view
        returns (bytes memory executeCallData)
    {
        if (executionData.length == 4) {
            // Selector-only mode (4 bytes)
            if (parentPromiseId != bytes32(0)) {
                // Has parent - selector + parent data
                Promise storage parent = promises[parentPromiseId];
                bytes4 selector = bytes4(executionData);
                executeCallData = abi.encodeWithSelector(selector, parent.returnData);
            } else {
                // No parent - just the selector (no parameters)
                executeCallData = executionData; // Direct 4-byte copy
            }
        } else if (executionData.length > 4) {
            // Full calldata mode (>4 bytes) - use as-is, ignore parent
            executeCallData = executionData;
        } else {
            revert("PromiseCallback: invalid execution data length");
        }
    }

    /// @notice Internal function to execute target contract
    /// @param promiseId The ID of the promise to execute
    function _executeTarget(bytes32 promiseId) internal {
        Promise memory promiseData = promises[promiseId];

        // Reentrancy protection
        require(currentExecutionContext == DEFAULT_EXECUTION_REGISTRANT, "PromiseCallback: re-entrant call detected");

        // Prepare call data based on execution mode
        bytes memory executeCallData = _prepareExecutionCallData(promiseData.executionData, promiseData.parentPromiseId);

        // Set execution context before execution
        currentExecutionContext = promiseData.creator;
        currentExecutionSourceChain = promiseData.sourceChain;

        // Execute the target
        (bool success, bytes memory returnData) = promiseData.target.call(executeCallData);

        // Clear execution context after execution
        currentExecutionContext = DEFAULT_EXECUTION_REGISTRANT;
        currentExecutionSourceChain = 0;

        // Update promise state
        if (success) {
            _resolvePromise(promiseId, returnData);
        } else {
            _rejectPromise(promiseId, returnData);
        }

        emit PromiseExecuted(promiseId, success, returnData);
    }

    /// @notice Internal function to resolve a promise
    /// @param promiseId The ID of the promise to resolve
    /// @param returnData The data to resolve the promise with
    function _resolvePromise(bytes32 promiseId, bytes memory returnData) internal {
        Promise storage promiseData = promises[promiseId];
        promiseData.status = PromiseStatus.Resolved;
        promiseData.returnData = returnData;

        emit PromiseResolved(promiseId, returnData);
    }

    /// @notice Internal function to reject a promise
    /// @param promiseId The ID of the promise to reject
    /// @param errorData The error data to reject the promise with
    function _rejectPromise(bytes32 promiseId, bytes memory errorData) internal {
        Promise storage promiseData = promises[promiseId];
        promiseData.status = PromiseStatus.Rejected;
        promiseData.returnData = errorData;

        emit PromiseRejected(promiseId, errorData);
    }

    /// @notice Internal function to check if dependency is met
    /// @param parentPromiseId The parent promise ID
    /// @param dependencyType How this promise relates to parent
    /// @return met Whether the dependency condition is satisfied
    function _checkDependency(bytes32 parentPromiseId, DependencyType dependencyType)
        internal
        view
        returns (bool met)
    {
        PromiseStatus parentStatus = promises[parentPromiseId].status;

        if (dependencyType == DependencyType.Then) {
            return parentStatus == PromiseStatus.Resolved;
        } else if (dependencyType == DependencyType.Catch) {
            return parentStatus == PromiseStatus.Rejected;
        }

        return false;
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /// @notice Get the status of a promise
    /// @param promiseId The ID of the promise to check
    /// @return promiseStatus The current status of the promise
    function status(bytes32 promiseId) external view returns (PromiseStatus promiseStatus) {
        return promises[promiseId].status;
    }

    /// @notice Get the full promise data
    /// @param promiseId The ID of the promise to get
    /// @return promiseData The complete promise data
    function getPromise(bytes32 promiseId) external view returns (Promise memory promiseData) {
        return promises[promiseId];
    }

    /// @notice Check if a promise exists
    /// @param promiseId The ID of the promise to check
    /// @return promiseExists Whether the promise exists
    function exists(bytes32 promiseId) external view returns (bool promiseExists) {
        return promises[promiseId].resolver != address(0);
    }

    /// @notice Get the current nonce
    /// @return The next nonce that will be assigned
    function getNonce() external view returns (uint256) {
        return nonce;
    }

    /// @notice Get the current execution context (during promise execution)
    /// @return creator The creator of the currently executing promise
    /// @return sourceChain The source chain of the currently executing promise
    function executionContext() external view returns (address creator, uint256 sourceChain) {
        return (currentExecutionContext, currentExecutionSourceChain);
    }

    // =============================================================================
    // CROSS-CHAIN FUNCTIONALITY
    // =============================================================================

    /// @notice Receive promise creation from another chain
    /// @param promiseId The promise ID to create
    /// @param resolver The address that can resolve this promise
    /// @param parentPromiseId The parent promise ID (bytes32(0) for none)
    /// @param dependencyType How this promise relates to its parent
    /// @param target The contract to call when resolving
    /// @param executionData Selector (4 bytes) or full calldata (>4 bytes)
    /// @param creator Who created this promise
    /// @param validator Custom validator contract address
    /// @param validationData Data for the validator
    function receivePromiseCreation(
        bytes32 promiseId,
        address resolver,
        bytes32 parentPromiseId,
        uint8 dependencyType,
        address target,
        bytes calldata executionData,
        address creator,
        address validator,
        bytes calldata validationData
    ) external {
        require(msg.sender == address(MESSENGER), "PromiseCallback: only messenger can call");
        require(
            MESSENGER.crossDomainMessageSender() == address(this), "PromiseCallback: only from PromiseCallback contract"
        );
        require(promises[promiseId].resolver == address(0), "PromiseCallback: promise already exists");

        promises[promiseId] = Promise({
            resolver: resolver,
            status: PromiseStatus.Pending,
            returnData: "",
            parentPromiseId: parentPromiseId,
            dependencyType: DependencyType(dependencyType),
            target: target,
            executionData: executionData,
            creator: creator,
            sourceChain: MESSENGER.crossDomainMessageSource(),
            validator: IValidator(validator),
            validationData: validationData
        });

        emit PromiseCreated(promiseId, resolver, creator);
    }

    /// @notice Share a resolved promise to another chain
    /// @param destinationChain The chain ID to share the promise with
    /// @param promiseId The ID of the promise to share
    function sharePromise(uint256 destinationChain, bytes32 promiseId) external {
        require(destinationChain != block.chainid, "PromiseCallback: cannot share to same chain");

        Promise memory promiseData = promises[promiseId];
        require(promiseData.status != PromiseStatus.Pending, "PromiseCallback: can only share settled promises");

        bytes memory message = abi.encodeCall(
            this.receiveSharedPromise,
            (promiseId, uint8(promiseData.status), promiseData.returnData, promiseData.resolver)
        );

        MESSENGER.sendMessage(destinationChain, address(this), message);

        emit PromiseShared(promiseId, destinationChain);
    }

    /// @notice Receive a shared promise from another chain
    /// @param promiseId The global promise ID
    /// @param promiseStatus The status of the shared promise
    /// @param returnData The return data of the shared promise
    /// @param resolver The resolver address of the shared promise
    function receiveSharedPromise(bytes32 promiseId, uint8 promiseStatus, bytes memory returnData, address resolver)
        external
    {
        require(msg.sender == address(MESSENGER), "PromiseCallback: only messenger can call");
        require(
            MESSENGER.crossDomainMessageSender() == address(this), "PromiseCallback: only from PromiseCallback contract"
        );
        require(promises[promiseId].resolver == address(0), "PromiseCallback: promise already exists");

        Promise storage promiseData = promises[promiseId];

        promiseData.resolver = resolver;
        promiseData.status = PromiseStatus(promiseStatus);
        promiseData.returnData = returnData;

        if (promiseData.status == PromiseStatus.Resolved) {
            emit PromiseResolved(promiseId, returnData);
        } else if (promiseData.status == PromiseStatus.Rejected) {
            emit PromiseRejected(promiseId, returnData);
        }
    }
}
