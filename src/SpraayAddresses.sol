// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Spraay batch contract deployments (SprayContract, verified on Sourcify)
/// @dev Only chains where both Spraay and the Uniswap V4 PoolManager are live are listed.
library SpraayAddresses {
    /// @dev BNB Chain mainnet, chainId 56
    address internal constant BSC_MAINNET = 0x3093a2951FB77b3beDfB8BA20De645F7413432C1;
    /// @dev Base mainnet, chainId 8453
    address internal constant BASE_MAINNET = 0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c;

    error UnsupportedChain(uint256 chainId);

    function forChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 56) return BSC_MAINNET;
        if (chainId == 8453) return BASE_MAINNET;
        revert UnsupportedChain(chainId);
    }
}
