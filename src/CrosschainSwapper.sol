// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "./Promise.sol";
import {UnifiedCallback} from "./UnifiedCallback.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {ISuperchainTokenBridge} from "./interfaces/ISuperchainTokenBridge.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ISuperchainERC20} from "./interfaces/ISuperchainERC20.sol";

contract CrosschainSwapper {
    error CrosschainSwapper__SwapFailed(address tokenIn, uint256 amountIn, address recipient, uint256 destinationId);
    error CrosschainSwapper__InvalidRouter();
    error CrosschainSwapper__InvalidCallback();

    Promise public immutable PROMISE;

    ISuperchainTokenBridge constant SUPERCHAIN_TOKEN_BRIDGE =
        ISuperchainTokenBridge(PredeployAddresses.SUPERCHAIN_TOKEN_BRIDGE);

    IL2ToL2CrossDomainMessenger constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    UnifiedCallback public immutable CALLBACK;
    address public immutable ROUTER;
    mapping(bytes32 msgHash => uint256 amountIn) public swapAmountIn;
    mapping(bytes32 msgHash => uint256 amountOut) public swapAmountOut;

    constructor(address _router, address _promise) {
        if (_router == address(0)) revert CrosschainSwapper__InvalidRouter();

        PROMISE = Promise(_promise);
        CALLBACK = new UnifiedCallback(address(PROMISE), address(MESSENGER));
        ROUTER = _router;
    }

    function initSwap(
        uint256 destinationId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (bytes32 bridgePromiseId, bytes32 swapCallbackId, bytes32 bridgeBackCallbackId) {
        // transfer tokens from user to this contract
        ISuperchainERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Execute the bridge to destination chain
        bytes32 messageHash = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(tokenIn, address(this), amountIn, destinationId);

        // Register amount to allow swap on destination chain
        bytes memory registerAmountMessage = abi.encodeWithSelector(this.registerAmount.selector, messageHash, amountIn);
        bytes32 registerAmountMessageHash = MESSENGER.sendMessage(destinationId, address(this), registerAmountMessage);

        // Create promise for this bridge operation
        bridgePromiseId = PROMISE.create();

        // Create hybrid callback to execute swap on destination chain when bridge promise resolves AND CDM message succeeds
        // This eliminates the redundant manual CDM check while preserving promise data transfer
        bytes32[] memory cdmHashes = new bytes32[](2);
        cdmHashes[0] = messageHash;
        cdmHashes[1] = registerAmountMessageHash;
        swapCallbackId =
            CALLBACK.thenOnWithCDM(destinationId, bridgePromiseId, address(this), this.relaySwap.selector, cdmHashes);

        // Create callbacks for bridging back - both success and failure cases
        bridgeBackCallbackId = CALLBACK.thenOn(destinationId, swapCallbackId, address(this), this.bridgeBack.selector);
        CALLBACK.catchErrorOn(destinationId, swapCallbackId, address(this), this.bridgeBackOnError.selector);

        // Resolve promise with bridge data and share to destination
        bytes memory promiseData = _encodePromiseData(messageHash, tokenIn, tokenOut, amountIn, minAmountOut, recipient);
        PROMISE.resolve(bridgePromiseId, promiseData);
        PROMISE.shareResolvedPromise(destinationId, bridgePromiseId);
    }

    function relaySwap(bytes memory data)
        external
        returns (bytes32 msgHash, address finalToken, uint256 finalAmount, address recipient, uint256 destinationId)
    {
        if (msg.sender != address(CALLBACK)) revert CrosschainSwapper__InvalidCallback();

        (
            bytes32 _msgHash,
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 minAmountOut,
            address recipientAddr,
            uint256 destId
        ) = abi.decode(data, (bytes32, address, address, uint256, uint256, address, uint256));

        require(swapAmountIn[_msgHash] == amountIn, "CrosschainSwapper: amount mismatch");
        // CDM success is guaranteed by UnifiedCallback's thenOnWithCDM - no need for manual check

        // Approve tokens for MockExchange
        ISuperchainERC20(tokenIn).approve(ROUTER, amountIn);

        // Execute swap on MockExchange
        (bool success, bytes memory returnData) =
            ROUTER.call(abi.encodeWithSignature("swap(address,address,uint256)", tokenIn, tokenOut, amountIn));

        if (!success) {
            revert CrosschainSwapper__SwapFailed(tokenIn, amountIn, recipientAddr, destId);
        }

        // Decode swap results - MockExchange returns uint256 amountOut
        uint256 amountOut = abi.decode(returnData, (uint256));

        // Verify minimum amount out
        if (amountOut < minAmountOut) {
            revert CrosschainSwapper__SwapFailed(tokenIn, amountIn, recipientAddr, destId);
        }

        swapAmountOut[_msgHash] = amountOut;

        msgHash = _msgHash;
        finalToken = tokenOut;
        finalAmount = amountOut;
        recipient = recipientAddr;
        destinationId = destId;
    }

    function bridgeBack(bytes memory data) external returns (bytes32 messageHash) {
        if (msg.sender != address(CALLBACK)) revert CrosschainSwapper__InvalidCallback();

        (bytes32 msgHash, address token, uint256 amountOut, address recipient, uint256 destinationId) =
            abi.decode(data, (bytes32, address, uint256, address, uint256));

        require(swapAmountOut[msgHash] == amountOut, "CrosschainSwapper: amount mismatch");

        // Bridge the swapped tokens back to original chain
        // Note: sendERC20 expects (token, recipient, amount, destinationId)
        messageHash = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(token, recipient, amountOut, destinationId);
    }

    function bridgeBackOnError(bytes memory data) external returns (bytes32 messageHash) {
        if (msg.sender != address(CALLBACK)) revert CrosschainSwapper__InvalidCallback();

        // Parse error data to extract original bridge information for refund
        // The error data contains the revert reason from relaySwap
        if (data.length >= 4) {
            bytes4 errorSelector;
            assembly {
                errorSelector := mload(add(data, 0x20))
            }

            if (errorSelector == CrosschainSwapper__SwapFailed.selector) {
                // Decode the error parameters to get refund information
                (, bytes32 msgHash, address tokenIn, uint256 amountIn, address recipient, uint256 destinationId) =
                    abi.decode(data, (bytes4, bytes32, address, uint256, address, uint256));

                require(swapAmountIn[msgHash] == amountIn, "CrosschainSwapper: amount mismatch");

                // Bridge back the original tokens as a refund
                messageHash = SUPERCHAIN_TOKEN_BRIDGE.sendERC20(tokenIn, recipient, amountIn, destinationId);
            }
        }

        // If we can't parse the error, we still need to return something
        // In a production system, you might want to emit an event for manual intervention
        return bytes32(0);
    }

    function registerAmount(bytes32 _msgHash, uint256 _amountIn) external {
        require(msg.sender == address(MESSENGER), "CrosschainSwapper: only callable by Messenger");
        require(
            MESSENGER.crossDomainMessageSender() == address(this),
            "CrosschainSwapper: only callable by CrosschainSwapper contract"
        );

        swapAmountIn[_msgHash] = _amountIn;
    }

    function _encodePromiseData(
        bytes32 messageHash,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) private view returns (bytes memory) {
        return abi.encode(messageHash, tokenIn, tokenOut, amountIn, minAmountOut, recipient, block.chainid);
    }
}
