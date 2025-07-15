// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {PromiseLib} from "./libraries/PromiseLib.sol";
import {PromiseCallback3} from "./PromiseCallback3.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {ISuperchainTokenBridge} from "./interfaces/ISuperchainTokenBridge.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ISuperchainERC20} from "./interfaces/ISuperchainERC20.sol";
import {IValidator} from "./interfaces/IValidator.sol";

contract CrosschainSwapper3 {
    using PromiseLib for PromiseCallback3;

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        uint256 destinationId;
    }

    error CrosschainSwapper__SwapFailed(address tokenIn, uint256 amountIn, address recipient, uint256 destinationId);
    error CrosschainSwapper__InvalidRouter();
    error CrosschainSwapper__InvalidCallback();
    error CrosschainSwapper__InvalidPromiseCallback();
    error CrosschainSwapper__InvalidCreator();

    event PromiseDataRegistered(bytes32 promiseData);

    ISuperchainTokenBridge constant SUPERCHAIN_TOKEN_BRIDGE =
        ISuperchainTokenBridge(PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE);

    IL2ToL2CrossDomainMessenger constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    PromiseCallback3 public immutable PROMISE_CALLBACK;
    address public immutable ROUTER;
    IValidator public immutable VALIDATOR;

    constructor(address _promiseCallback, address _router, address _validator) {
        if (_router == address(0)) revert CrosschainSwapper__InvalidRouter();
        if (_promiseCallback == address(0)) revert CrosschainSwapper__InvalidPromiseCallback();

        PROMISE_CALLBACK = PromiseCallback3(_promiseCallback);
        ROUTER = _router;
        VALIDATOR = IValidator(_validator);
    }

    function initSwap(
        uint256 destinationId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (bytes32 bridgeId, bytes32 bridgeBackId, bytes32 bridgeBackOnErrorId) {
        // transfer tokens from user to this contract
        ISuperchainERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Send tokens to destination chain
        bytes32 sendERC20MessageHash =
            SUPERCHAIN_TOKEN_BRIDGE.sendERC20(tokenIn, address(this), amountIn, destinationId);

        // Create promise for bridge to destination chain
        SwapParams memory params = SwapParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            recipient: recipient,
            destinationId: destinationId
        });
        bridgeId = _createBridgePromise(sendERC20MessageHash, params);

        // Attach then to bridge promise
        bridgeBackId = PROMISE_CALLBACK.thenOn(bridgeId, destinationId, address(this), this.bridgeBack.selector);
        // Attach catch to bridge promise
        bridgeBackOnErrorId =
            PROMISE_CALLBACK.catchErrorOn(bridgeId, destinationId, address(this), this.bridgeBackOnError.selector);
    }

    function relaySwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 destinationId
    ) external returns (address finalToken, uint256 finalAmount, address finalRecipient, uint256 finalDestinationId) {
        if (msg.sender != address(PROMISE_CALLBACK)) revert CrosschainSwapper__InvalidCallback();
        (address creator,) = PROMISE_CALLBACK.executionContext();
        if (creator != address(this)) revert CrosschainSwapper__InvalidCreator();

        // Approve tokens for MockExchange
        ISuperchainERC20(tokenIn).approve(ROUTER, amountIn);

        // Execute swap on MockExchange
        (bool success, bytes memory returnData) =
            ROUTER.call(abi.encodeWithSignature("swap(address,address,uint256)", tokenIn, tokenOut, amountIn));

        if (!success) {
            revert CrosschainSwapper__SwapFailed(tokenIn, amountIn, recipient, destinationId);
        }

        // Decode swap results - MockExchange returns uint256 amountOut
        uint256 amountOut = abi.decode(returnData, (uint256));

        // Verify minimum amount out
        if (amountOut < minAmountOut) {
            revert CrosschainSwapper__SwapFailed(tokenIn, amountIn, recipient, destinationId);
        }

        return (tokenOut, amountOut, recipient, destinationId);
    }

    function bridgeBack(bytes memory data) external returns (bytes32 messageHash) {
        if (msg.sender != address(PROMISE_CALLBACK)) revert CrosschainSwapper__InvalidCallback();
        (address creator,) = PROMISE_CALLBACK.executionContext();
        if (creator != address(this)) revert CrosschainSwapper__InvalidCreator();

        (address token, uint256 amountOut, address recipient, uint256 destinationId) =
            abi.decode(data, (address, uint256, address, uint256));

        // Bridge the swapped tokens back to original chain
        messageHash = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(token, recipient, amountOut, destinationId);
    }

    function bridgeBackOnError(bytes memory data) external returns (bytes32 messageHash) {
        if (msg.sender != address(PROMISE_CALLBACK)) revert CrosschainSwapper__InvalidCallback();
        (address creator,) = PROMISE_CALLBACK.executionContext();
        if (creator != address(this)) revert CrosschainSwapper__InvalidCreator();

        // Parse error data to extract original bridge information for refund
        // The error data contains the revert reason from relaySwap
        if (data.length >= 4) {
            bytes4 errorSelector;
            assembly {
                errorSelector := mload(add(data, 0x20))
            }

            if (errorSelector == CrosschainSwapper__SwapFailed.selector) {
                // Extract the error parameters by skipping the first 4 bytes (error selector)
                bytes memory errorData = new bytes(data.length - 4);
                assembly {
                    let src := add(data, 0x24) // skip 32 bytes (length) + 4 bytes (selector)
                    let dst := add(errorData, 0x20) // skip 32 bytes (length)
                    let len := sub(mload(data), 4) // data length - 4 bytes
                    let success := call(gas(), 0x4, 0, src, len, dst, len) // copy using identity precompile
                }

                // Decode the error parameters to get refund information
                (address tokenIn, uint256 amountIn, address recipient, uint256 destinationId) =
                    abi.decode(errorData, (address, uint256, address, uint256));

                // Bridge back the original tokens as a refund
                messageHash = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(tokenIn, recipient, amountIn, destinationId);
            }
        }

        return bytes32(0);
    }

    function _createBridgePromise(bytes32 sendERC20MessageHash, SwapParams memory params)
        private
        returns (bytes32 bridgeId)
    {
        bytes32[] memory msgHashes = new bytes32[](1);
        msgHashes[0] = sendERC20MessageHash;

        bridgeId = PROMISE_CALLBACK.create(
            address(this), // resolver
            bytes32(0), // parent promise id
            PromiseCallback3.DependencyType.None, // dependency type
            address(this), // target
            abi.encodeCall(
                this.relaySwap,
                (params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.recipient, block.chainid)
            ), // execution data
            VALIDATOR, // validator
            abi.encode(msgHashes), // validation data
            params.destinationId
        );
    }
}
