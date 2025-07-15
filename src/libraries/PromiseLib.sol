// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PromiseCallback3} from "../PromiseCallback3.sol";
import {IValidator} from "../interfaces/IValidator.sol";

/// @title PromiseLib
/// @notice Convenience library for simplified promise creation with PromiseCallback3
/// @dev Provides developer-friendly wrappers around the core create() function
library PromiseLib {
    // =============================================================================
    // SIMPLE PROMISE CREATION
    // =============================================================================

    /// @notice Create a basic manual promise
    /// @return promiseId The unique identifier for the new promise
    function createManual(PromiseCallback3 callback) internal returns (bytes32 promiseId) {
        return callback.create(
            msg.sender, // caller is resolver
            bytes32(0), // no parent
            PromiseCallback3.DependencyType.None,
            address(0), // manual resolution
            "", // no execution data
            IValidator(address(0)), // no validator
            "", // no validation data
            0 // current chain
        );
    }

    /// @notice Create an auto-executing promise with just a selector
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @return promiseId The unique identifier for the new promise
    function createAuto(PromiseCallback3 callback, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback), // contract resolves it
            bytes32(0), // no parent
            PromiseCallback3.DependencyType.None,
            target,
            abi.encodePacked(selector),
            IValidator(address(0)),
            "",
            0 // current chain
        );
    }

    /// @notice Create an auto-executing promise with full calldata
    /// @param target The contract to call when resolving
    /// @param callData The complete calldata for the call
    /// @return promiseId The unique identifier for the new promise
    function createAutoWithCalldata(PromiseCallback3 callback, address target, bytes memory callData)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback), // contract resolves it
            bytes32(0), // no parent
            PromiseCallback3.DependencyType.None,
            target,
            callData,
            IValidator(address(0)),
            "",
            0 // current chain
        );
    }

    /// @notice Create a promise with custom validation
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The unique identifier for the new promise
    function createWithValidator(
        PromiseCallback3 callback,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return callback.create(
            address(callback),
            bytes32(0),
            PromiseCallback3.DependencyType.None,
            target,
            abi.encodePacked(selector),
            validator,
            validationData,
            0
        );
    }

    // =============================================================================
    // PROMISE CALLBACKS
    // =============================================================================

    /// @notice Add a then callback with just selector (local)
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent resolves
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function then(PromiseCallback3 callback, bytes32 parentId, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Then,
            target,
            abi.encodePacked(selector),
            IValidator(address(0)),
            "",
            0 // current chain
        );
    }

    /// @notice Add a then callback with validator
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent resolves
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function then(
        PromiseCallback3 callback,
        bytes32 parentId,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Then,
            target,
            abi.encodePacked(selector),
            validator,
            validationData,
            0 // current chain
        );
    }

    /// @notice Add a catch callback with just selector (local)
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent rejects
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function catchError(PromiseCallback3 callback, bytes32 parentId, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Catch,
            target,
            abi.encodePacked(selector),
            IValidator(address(0)),
            "",
            0 // current chain
        );
    }

    /// @notice Add a catch callback with validator
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent rejects
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function catchError(
        PromiseCallback3 callback,
        bytes32 parentId,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Catch,
            target,
            abi.encodePacked(selector),
            validator,
            validationData,
            0 // current chain
        );
    }

    // =============================================================================
    // CROSS-CHAIN SHORTCUTS
    // =============================================================================

    /// @notice Create a manual promise on another chain
    /// @param chain The destination chain ID
    /// @return promiseId The unique identifier for the new promise
    function createManualOn(PromiseCallback3 callback, uint256 chain) internal returns (bytes32 promiseId) {
        return callback.create(
            msg.sender,
            bytes32(0),
            PromiseCallback3.DependencyType.None,
            address(0),
            "",
            IValidator(address(0)),
            "",
            chain
        );
    }

    /// @notice Create an auto-executing promise on another chain
    /// @param chain The destination chain ID
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @return promiseId The unique identifier for the new promise
    function createAutoOn(PromiseCallback3 callback, uint256 chain, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback),
            bytes32(0),
            PromiseCallback3.DependencyType.None,
            target,
            abi.encodePacked(selector),
            IValidator(address(0)),
            "",
            chain
        );
    }

    /// @notice Add then callback on another chain
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent resolves
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function thenOn(PromiseCallback3 callback, bytes32 parentId, uint256 chain, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Then,
            target,
            abi.encodePacked(selector),
            IValidator(address(0)),
            "",
            chain
        );
    }

    /// @notice Add then callback on another chain with validator
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent resolves
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function thenOn(
        PromiseCallback3 callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Then,
            target,
            abi.encodePacked(selector),
            validator,
            validationData,
            chain
        );
    }

    /// @notice Add catch callback on another chain
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent rejects
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function catchErrorOn(PromiseCallback3 callback, bytes32 parentId, uint256 chain, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Catch,
            target,
            abi.encodePacked(selector),
            IValidator(address(0)),
            "",
            chain
        );
    }

    /// @notice Add catch callback on another chain with validator
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent rejects
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function catchErrorOn(
        PromiseCallback3 callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return callback.create(
            address(callback),
            parentId,
            PromiseCallback3.DependencyType.Catch,
            target,
            abi.encodePacked(selector),
            validator,
            validationData,
            chain
        );
    }

    // =============================================================================
    // COMMON PATTERNS
    // =============================================================================

    /// @notice Create a promise chain: execute A, then B, then C
    /// @param targets Array of contracts to call in sequence
    /// @param selectors Array of function selectors to call
    /// @return finalPromiseId The ID of the last promise in the chain
    function createChain(PromiseCallback3 callback, address[] memory targets, bytes4[] memory selectors)
        internal
        returns (bytes32 finalPromiseId)
    {
        require(targets.length > 0 && targets.length == selectors.length, "PromiseLib: invalid chain");

        // Create first promise
        bytes32 currentPromise = createAuto(callback, targets[0], selectors[0]);

        // Chain the rest
        for (uint256 i = 1; i < targets.length; i++) {
            currentPromise = then(callback, currentPromise, targets[i], selectors[i]);
        }

        return currentPromise;
    }
}
