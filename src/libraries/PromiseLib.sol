// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IPromiseCallback} from "../interfaces/IPromiseCallback.sol";
import {IValidator} from "../interfaces/IValidator.sol";

/// @title PromiseLib
/// @notice Convenience library for simplified promise creation with PromiseCallback
/// @dev Provides developer-friendly wrappers around the core create() function
library PromiseLib {
    // =============================================================================
    // INTERNAL HELPERS
    // =============================================================================

    /// @notice Internal function to create a promise with common defaults
    /// @param resolver The address that can resolve this promise
    /// @param parentId The parent promise ID (bytes32(0) for none)
    /// @param dependencyType The dependency type
    /// @param target The contract to call when resolving
    /// @param executionData The execution data (selector or full calldata)
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @param chain The destination chain ID
    /// @return promiseId The unique identifier for the new promise
    function _createPromise(
        IPromiseCallback callback,
        address resolver,
        bytes32 parentId,
        IPromiseCallback.DependencyType dependencyType,
        address target,
        bytes memory executionData,
        IValidator validator,
        bytes memory validationData,
        uint256 chain
    ) private returns (bytes32 promiseId) {
        return
            callback.create(resolver, parentId, dependencyType, target, executionData, validator, validationData, chain);
    }

    /// @notice Create promise with no parent (root promise)
    /// @param resolver The address that can resolve this promise
    /// @param target The contract to call when resolving
    /// @param executionData The execution data
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @param chain The destination chain ID
    /// @return promiseId The unique identifier for the new promise
    function _createRootPromise(
        IPromiseCallback callback,
        address resolver,
        address target,
        bytes memory executionData,
        IValidator validator,
        bytes memory validationData,
        uint256 chain
    ) private returns (bytes32 promiseId) {
        return _createPromise(
            callback,
            resolver,
            bytes32(0),
            IPromiseCallback.DependencyType.None,
            target,
            executionData,
            validator,
            validationData,
            chain
        );
    }

    /// @notice Create a callback promise (then or catch)
    /// @param parentId The parent promise ID
    /// @param dependencyType Then or Catch
    /// @param target The contract to call
    /// @param executionData The execution data
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @param chain The destination chain ID
    /// @return promiseId The unique identifier for the new promise
    function _createCallback(
        IPromiseCallback callback,
        bytes32 parentId,
        IPromiseCallback.DependencyType dependencyType,
        address target,
        bytes memory executionData,
        IValidator validator,
        bytes memory validationData,
        uint256 chain
    ) private returns (bytes32 promiseId) {
        return _createPromise(
            callback,
            address(callback),
            parentId,
            dependencyType,
            target,
            executionData,
            validator,
            validationData,
            chain
        );
    }

    /// @notice Prepare execution data from selector
    /// @param selector The function selector
    /// @return executionData The packed execution data
    function _prepareExecutionData(bytes4 selector) private pure returns (bytes memory) {
        return abi.encodePacked(selector);
    }

    // =============================================================================
    // SIMPLE PROMISE CREATION
    // =============================================================================

    /// @notice Create a basic manual promise
    /// @return promiseId The unique identifier for the new promise
    function createManual(IPromiseCallback callback) internal returns (bytes32 promiseId) {
        return _createRootPromise(callback, msg.sender, address(0), "", IValidator(address(0)), "", 0);
    }

    /// @notice Create a manual promise with custom resolver
    /// @param resolver The address that can resolve this promise
    /// @return promiseId The unique identifier for the new promise
    function createManual(IPromiseCallback callback, address resolver) internal returns (bytes32 promiseId) {
        return _createRootPromise(callback, resolver, address(0), "", IValidator(address(0)), "", 0);
    }

    /// @notice Create a manual promise with custom resolver on another chain
    /// @param resolver The address that can resolve this promise
    /// @param chain The destination chain ID
    /// @return promiseId The unique identifier for the new promise
    function createManual(IPromiseCallback callback, address resolver, uint256 chain)
        internal
        returns (bytes32 promiseId)
    {
        return _createRootPromise(callback, resolver, address(0), "", IValidator(address(0)), "", chain);
    }

    /// @notice Create an auto-executing promise with just a selector
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @return promiseId The unique identifier for the new promise
    function createAuto(IPromiseCallback callback, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return _createRootPromise(
            callback, address(callback), target, _prepareExecutionData(selector), IValidator(address(0)), "", 0
        );
    }

    /// @notice Create an auto-executing promise with full calldata
    /// @param target The contract to call when resolving
    /// @param callData The complete calldata for the call
    /// @return promiseId The unique identifier for the new promise
    function createAuto(IPromiseCallback callback, address target, bytes memory callData)
        internal
        returns (bytes32 promiseId)
    {
        return _createRootPromise(callback, address(callback), target, callData, IValidator(address(0)), "", 0);
    }

    /// @notice Create a promise with custom validation
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The unique identifier for the new promise
    function createAuto(
        IPromiseCallback callback,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createRootPromise(
            callback, address(callback), target, _prepareExecutionData(selector), validator, validationData, 0
        );
    }

    /// @notice Create an auto-executing promise with calldata and validator
    /// @param target The contract to call when resolving
    /// @param callData The complete calldata for the call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The unique identifier for the new promise
    function createAuto(
        IPromiseCallback callback,
        address target,
        bytes memory callData,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createRootPromise(callback, address(callback), target, callData, validator, validationData, 0);
    }

    /// @notice Create an auto-executing promise with calldata on another chain
    /// @param chain The destination chain ID
    /// @param target The contract to call when resolving
    /// @param callData The complete calldata for the call
    /// @return promiseId The unique identifier for the new promise
    function createAuto(IPromiseCallback callback, uint256 chain, address target, bytes memory callData)
        internal
        returns (bytes32 promiseId)
    {
        return _createRootPromise(callback, address(callback), target, callData, IValidator(address(0)), "", chain);
    }

    // =============================================================================
    // PROMISE CALLBACKS
    // =============================================================================

    /// @notice Add a then callback with just selector (local)
    /// @param parentId The parent promise ID to watch
    /// @param target The contract to call when parent resolves
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function then(IPromiseCallback callback, bytes32 parentId, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Then,
            target,
            _prepareExecutionData(selector),
            IValidator(address(0)),
            "",
            0
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
        IPromiseCallback callback,
        bytes32 parentId,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Then,
            target,
            _prepareExecutionData(selector),
            validator,
            validationData,
            0
        );
    }

    /// @notice Add a then callback with full calldata
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent resolves
    /// @param callData The complete calldata for the call
    /// @return promiseId The ID of the created promise
    function then(IPromiseCallback callback, bytes32 parentId, address target, bytes memory callData)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback, parentId, IPromiseCallback.DependencyType.Then, target, callData, IValidator(address(0)), "", 0
        );
    }

    /// @notice Add a then callback with full calldata and validator
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent resolves
    /// @param callData The complete calldata for the call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function then(
        IPromiseCallback callback,
        bytes32 parentId,
        address target,
        bytes memory callData,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback, parentId, IPromiseCallback.DependencyType.Then, target, callData, validator, validationData, 0
        );
    }

    /// @notice Add a catch callback with just selector (local)
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent rejects
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function catchError(IPromiseCallback callback, bytes32 parentId, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Catch,
            target,
            _prepareExecutionData(selector),
            IValidator(address(0)),
            "",
            0
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
        IPromiseCallback callback,
        bytes32 parentId,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Catch,
            target,
            _prepareExecutionData(selector),
            validator,
            validationData,
            0
        );
    }

    /// @notice Add a catch callback with full calldata
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent rejects
    /// @param callData The complete calldata for the call
    /// @return promiseId The ID of the created promise
    function catchError(IPromiseCallback callback, bytes32 parentId, address target, bytes memory callData)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback, parentId, IPromiseCallback.DependencyType.Catch, target, callData, IValidator(address(0)), "", 0
        );
    }

    /// @notice Add a catch callback with full calldata and validator
    /// @param parentId The parent promise to watch
    /// @param target The contract to call when parent rejects
    /// @param callData The complete calldata for the call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function catchError(
        IPromiseCallback callback,
        bytes32 parentId,
        address target,
        bytes memory callData,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback, parentId, IPromiseCallback.DependencyType.Catch, target, callData, validator, validationData, 0
        );
    }

    // =============================================================================
    // CROSS-CHAIN SHORTCUTS
    // =============================================================================

    /// @notice Create a manual promise on another chain
    /// @param chain The destination chain ID
    /// @return promiseId The unique identifier for the new promise
    function createManualOn(IPromiseCallback callback, uint256 chain) internal returns (bytes32 promiseId) {
        return _createRootPromise(callback, msg.sender, address(0), "", IValidator(address(0)), "", chain);
    }

    /// @notice Create an auto-executing promise on another chain
    /// @param chain The destination chain ID
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @return promiseId The unique identifier for the new promise
    function createAutoOn(IPromiseCallback callback, uint256 chain, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return _createRootPromise(
            callback, address(callback), target, _prepareExecutionData(selector), IValidator(address(0)), "", chain
        );
    }

    /// @notice Create an auto-executing promise on another chain with validator
    /// @param chain The destination chain ID
    /// @param target The contract to call when resolving
    /// @param selector The function selector to call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The unique identifier for the new promise
    function createAutoOn(
        IPromiseCallback callback,
        uint256 chain,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createRootPromise(
            callback, address(callback), target, _prepareExecutionData(selector), validator, validationData, chain
        );
    }

    /// @notice Create an auto-executing promise on another chain with full calldata and validator
    /// @param chain The destination chain ID
    /// @param target The contract to call when resolving
    /// @param callData The complete calldata for the call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The unique identifier for the new promise
    function createAutoOn(
        IPromiseCallback callback,
        uint256 chain,
        address target,
        bytes memory callData,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createRootPromise(callback, address(callback), target, callData, validator, validationData, chain);
    }

    /// @notice Add then callback on another chain
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent resolves
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function thenOn(IPromiseCallback callback, bytes32 parentId, uint256 chain, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Then,
            target,
            _prepareExecutionData(selector),
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
        IPromiseCallback callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Then,
            target,
            _prepareExecutionData(selector),
            validator,
            validationData,
            chain
        );
    }

    /// @notice Add then callback on another chain with full calldata
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent resolves
    /// @param callData The complete calldata for the call
    /// @return promiseId The ID of the created promise
    function thenOn(IPromiseCallback callback, bytes32 parentId, uint256 chain, address target, bytes memory callData)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Then,
            target,
            callData,
            IValidator(address(0)),
            "",
            chain
        );
    }

    /// @notice Add then callback on another chain with full calldata and validator
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent resolves
    /// @param callData The complete calldata for the call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function thenOn(
        IPromiseCallback callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes memory callData,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback, parentId, IPromiseCallback.DependencyType.Then, target, callData, validator, validationData, chain
        );
    }

    /// @notice Add catch callback on another chain
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent rejects
    /// @param selector The function selector to call
    /// @return promiseId The ID of the created promise
    function catchErrorOn(IPromiseCallback callback, bytes32 parentId, uint256 chain, address target, bytes4 selector)
        internal
        returns (bytes32 promiseId)
    {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Catch,
            target,
            _prepareExecutionData(selector),
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
        IPromiseCallback callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes4 selector,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Catch,
            target,
            _prepareExecutionData(selector),
            validator,
            validationData,
            chain
        );
    }

    /// @notice Add catch callback on another chain with full calldata
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent rejects
    /// @param callData The complete calldata for the call
    /// @return promiseId The ID of the created promise
    function catchErrorOn(
        IPromiseCallback callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes memory callData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Catch,
            target,
            callData,
            IValidator(address(0)),
            "",
            chain
        );
    }

    /// @notice Add catch callback on another chain with full calldata and validator
    /// @param parentId The parent promise to watch
    /// @param chain The destination chain ID
    /// @param target The contract to call when parent rejects
    /// @param callData The complete calldata for the call
    /// @param validator The validator contract
    /// @param validationData Data for the validator
    /// @return promiseId The ID of the created promise
    function catchErrorOn(
        IPromiseCallback callback,
        bytes32 parentId,
        uint256 chain,
        address target,
        bytes memory callData,
        IValidator validator,
        bytes memory validationData
    ) internal returns (bytes32 promiseId) {
        return _createCallback(
            callback,
            parentId,
            IPromiseCallback.DependencyType.Catch,
            target,
            callData,
            validator,
            validationData,
            chain
        );
    }
}
