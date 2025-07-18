// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IResolvable} from "./IResolvable.sol";
import {IL2ToL2CrossDomainMessenger} from "./IL2ToL2CrossDomainMessenger.sol";
import {IValidator} from "./IValidator.sol";

/// @title IPromiseCallback
/// @notice Interface for the PromiseCallback contract
/// @dev Pure promise system where everything is a promise
interface IPromiseCallback is IResolvable {
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
    function generateGlobalPromiseId(bytes32 nonceValue) external view returns (bytes32 globalPromiseId);

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
    ) external returns (bytes32 promiseId);

    /// @notice Resolve any promise - unified resolution path
    /// @param promiseId The ID of the promise to resolve
    function resolve(bytes32 promiseId) external;

    /// @notice Manually resolve a promise with specific data
    /// @param promiseId The ID of the promise to resolve
    /// @param returnData The data to resolve the promise with
    function resolveWith(bytes32 promiseId, bytes calldata returnData) external;

    /// @notice Reject a promise with error data
    /// @param promiseId The ID of the promise to reject
    /// @param errorData The error data to reject the promise with
    function reject(bytes32 promiseId, bytes memory errorData) external;

    /// @notice Check if a promise can be resolved
    /// @param promiseId The ID of the promise to check
    /// @return canResolvePromise Whether the promise can be resolved now
    function canResolve(bytes32 promiseId) external view returns (bool canResolvePromise);

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /// @notice Get the status of a promise
    /// @param promiseId The ID of the promise to check
    /// @return promiseStatus The current status of the promise
    function status(bytes32 promiseId) external view returns (PromiseStatus promiseStatus);

    /// @notice Get the full promise data
    /// @param promiseId The ID of the promise to get
    /// @return promiseData The complete promise data
    function getPromise(bytes32 promiseId) external view returns (Promise memory promiseData);

    /// @notice Check if a promise exists
    /// @param promiseId The ID of the promise to check
    /// @return promiseExists Whether the promise exists
    function exists(bytes32 promiseId) external view returns (bool promiseExists);

    /// @notice Get the current nonce
    /// @return The next nonce that will be assigned
    function getNonce() external view returns (uint256);

    /// @notice Get the current execution context (during promise execution)
    /// @return creator The creator of the currently executing promise
    /// @return sourceChain The source chain of the currently executing promise
    function executionContext() external view returns (address creator, uint256 sourceChain);

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
    ) external;

    /// @notice Share a resolved promise to another chain
    /// @param destinationChain The chain ID to share the promise with
    /// @param promiseId The ID of the promise to share
    function sharePromise(uint256 destinationChain, bytes32 promiseId) external;

    /// @notice Receive a shared promise from another chain
    /// @param promiseId The global promise ID
    /// @param promiseStatus The status of the shared promise
    /// @param returnData The return data of the shared promise
    /// @param resolver The resolver address of the shared promise
    function receiveSharedPromise(bytes32 promiseId, uint8 promiseStatus, bytes memory returnData, address resolver)
        external;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Mapping from promise ID to promise data
    function promises(bytes32 promiseId) external view returns (Promise memory);

    /// @notice Cross-domain messenger for cross-chain operations
    function MESSENGER() external view returns (IL2ToL2CrossDomainMessenger);
}
