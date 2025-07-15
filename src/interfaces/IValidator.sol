// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IValidator {
    function canResolve(bytes calldata validationData) external view returns (bool canResolve);
}
