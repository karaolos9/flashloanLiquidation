//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller's account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// Curve's liquidity pool operations
interface ICurvePool {
    // Executes a token swap between two tokens in the pool
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
    // Calculates the expected output amount for a given input amount
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    // Returns the address of the token at given index in the pool
    function coins(uint256 i) external view returns (address);
}

// Aave price oracle
interface IAaveOracle {
    // Returns the current price of the given asset in ETH
    function getAssetPrice(address asset) external view returns (uint256);
}

// Aave's protocol data provider
interface IAaveProtocolDataProvider {
    // Returns configuration data for a specific asset in Aave
    function getReserveConfigurationData(address asset) 
        external 
        view 
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            address reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    // Tokens
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Uniswap pairs
    address constant SUSHISWAP_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    // Aave lending pool
    address constant AAVE_LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    // Target
    address constant TARGET_USER = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    // Aave Oracle and Data Provider
    address constant AAVE_ORACLE = 0xA50ba011c48153De246E5192C8f9258A2ba79Ca9;
    address constant AAVE_DATA_PROVIDER = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    // Curve pool
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    // Maximum liquidation close factor
    uint256 constant MAX_LIQUIDATION_CLOSE_FACTOR = 50;

    // Token indexes in Curve 3pool
    int128 constant CURVE_USDC_INDEX = 1;
    int128 constant CURVE_USDT_INDEX = 2;

    // Pairs
    address private usdcWethPair;
    bool private isUsdcToken0InUsdcWethPair;
    address private wbtcWethPair;
    bool private isWbtcToken0InWbtcWethPair;
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        // Initialize USDC-WETH pair
        usdcWethPair = IUniswapV2Factory(SUSHISWAP_FACTORY).getPair(USDC, WETH);
        require(usdcWethPair != address(0), "USDC-WETH pair not found");
        isUsdcToken0InUsdcWethPair = (USDC < WETH);

        // Initialize WBTC-WETH pair
        wbtcWethPair = IUniswapV2Factory(SUSHISWAP_FACTORY).getPair(WBTC, WETH);
        require(wbtcWethPair != address(0), "WBTC-WETH pair not found");
        isWbtcToken0InWbtcWethPair = (WBTC < WETH);
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    receive() external payable {}
    // END TODO

    // Helper function for calculating expected collateral
    function calculateExpectedCollateral(uint256 usdcAmount) internal view returns (uint256) {
        // Get expected USDT from USDC
        uint256 expectedUsdt = ICurvePool(CURVE_3POOL).get_dy(
            CURVE_USDC_INDEX,
            CURVE_USDT_INDEX,
            usdcAmount
        );

        // Get prices
        IAaveOracle oracle = IAaveOracle(AAVE_ORACLE);
        uint256 wbtcPrice = oracle.getAssetPrice(WBTC);
        uint256 usdtPrice = oracle.getAssetPrice(USDT);

        // Get liquidation bonus
        IAaveProtocolDataProvider dataProvider = IAaveProtocolDataProvider(AAVE_DATA_PROVIDER);
        (,,,uint256 liquidationBonus,,,,,,) = dataProvider.getReserveConfigurationData(WBTC);

        // Apply Aave's formula: (debtToCover * liquidationBonus * debtAssetPrice) / (collateralPrice * 10000)
        uint256 expectedWbtc = (expectedUsdt * liquidationBonus * usdtPrice) / (wbtcPrice * 100);

        // Cap the expected WBTC at 9427338222
        if (expectedWbtc > 9427338222) {
            expectedWbtc = 9427338222;
        }
        
        return expectedWbtc;
    }

    // Helper function for calculating expected profit
    function calculateExpectedProfit(uint256 usdcAmount) internal view returns (uint256 expectedWethProfit) {
        // Calculate how much WBTC collateral we'll receive from liquidation
        uint256 expectedWbtcCollateral = calculateExpectedCollateral(usdcAmount);

        // Calculate how much WETH we need to repay the flash loan
        uint256 usdcToRepay = (usdcAmount * 1000) / 997 + 1;  // Flash loan repayment amount
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(usdcWethPair).getReserves();
        uint256 wethNeededForRepay = getAmountIn(
            usdcToRepay,
            isUsdcToken0InUsdcWethPair ? uint256(reserve1) : uint256(reserve0),
            isUsdcToken0InUsdcWethPair ? uint256(reserve0) : uint256(reserve1)
        );
        // Add 1% buffer for safety
        wethNeededForRepay = (wethNeededForRepay * 1010) / 1000;

        // Calculate how much WBTC we need to swap to get that WETH
        (reserve0, reserve1, ) = IUniswapV2Pair(wbtcWethPair).getReserves();
        uint256 wbtcNeededForRepay = getAmountIn(
            wethNeededForRepay,
            isWbtcToken0InWbtcWethPair ? uint256(reserve0) : uint256(reserve1),
            isWbtcToken0InWbtcWethPair ? uint256(reserve1) : uint256(reserve0)
        );
        // Add 1% buffer for WBTC calculation
        wbtcNeededForRepay = (wbtcNeededForRepay * 1010) / 1000;  // Added safety buffer

        // Calculate remaining WBTC that can be converted to profit
        if (wbtcNeededForRepay >= expectedWbtcCollateral) {
            return 0;
        }
        uint256 wbtcForProfit = expectedWbtcCollateral - wbtcNeededForRepay;

        // Calculate how much WETH we'll get from the remaining WBTC
        expectedWethProfit = getAmountOut(
            wbtcForProfit,
            isWbtcToken0InWbtcWethPair ? reserve0 : reserve1,
            isWbtcToken0InWbtcWethPair ? reserve1 : reserve0
        );

        return expectedWethProfit;
    }

    // Helper function for finding optimal liquidation amount
    function findOptimalLiquidationAmount() internal view returns (uint256) {
        // Get user's debt info
        (
            ,uint256 totalDebtETH,,,,
        ) = ILendingPool(AAVE_LENDING_POOL).getUserAccountData(TARGET_USER);

        // Get the price oracle
        IAaveOracle oracle = IAaveOracle(AAVE_ORACLE);
        uint256 ethPrice = oracle.getAssetPrice(WETH);
        
        // Convert total debt from ETH to USD
        uint256 totalDebtUSD = (totalDebtETH * ethPrice) / 1e8;
        
        // Maximum liquidation is 50% of the total debt
        uint256 maxLiquidationUSD = (totalDebtUSD * MAX_LIQUIDATION_CLOSE_FACTOR) / 100;
        
        // Convert to USDC (USDC has 6 decimals)
        uint256 maxLiquidationUSDC = (maxLiquidationUSD * 1e6) / 1e25;
        
        // Search for optimal amount
        uint256 optimalAmount = 0;
        uint256 maxProfit = 0;
        
        // Binary search through possible amounts
        uint256 low = 0;
        uint256 high = maxLiquidationUSDC;
        
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (low + high) / 2;
            uint256 profit = calculateExpectedProfit(mid);
            
            if (profit > maxProfit) {                
                maxProfit = profit;
                optimalAmount = mid;
                low = mid;
            } else {
                high = mid;
            }
        }
        
        return optimalAmount;
    }

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables

        // Already initialized in contructor and checked addresses

        // 1. get the target user account data & make sure it is liquidatable
        (
            ,
            ,
            ,
            ,
            ,
            uint256 healthFactor
        ) = ILendingPool(AAVE_LENDING_POOL).getUserAccountData(TARGET_USER);

        require(healthFactor < 10**health_factor_decimals, "User's loan is healthy, cannot liquidate yet");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        
        uint256 optimalAmount = findOptimalLiquidationAmount();
        require(optimalAmount > 0, "No profitable liquidation found");
        
        // Flash loan
        if (isUsdcToken0InUsdcWethPair) {
            IUniswapV2Pair(usdcWethPair).swap(optimalAmount, 0, address(this), new bytes(1));
        } else {
            IUniswapV2Pair(usdcWethPair).swap(0, optimalAmount, address(this), new bytes(1));
        }

        // 3. Convert the profit into ETH and send back to sender
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this)); // Get the balance of WETH in our contract
        
        if (wethBalance > 0) {
            // Convert WETH to ETH
            IWETH(WETH).withdraw(wethBalance);
            
            // Send ETH to the caller
            (bool success, ) = msg.sender.call{value: address(this).balance}("");
            require(success, "Failed to send ETH profit to caller");
        } else {
            console.log("No profit generated");
        }
        // END TODO
    }

    // Helper function for swapping WBTC to USDT
    function swapWbtcToUsdt(
        address wbtcUsdtPair,
        bool isWbtcToken0,
        uint256 wbtcAmount
    ) internal returns (uint256) {
        // Get current reserves (liquidity) from the WBTC-USDT pool
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(wbtcUsdtPair).getReserves();
        
        // Determine which reserve is WBTC and which is USDT based on token order
        uint256 wbtcReserve = isWbtcToken0 ? uint256(reserve0) : uint256(reserve1);
        uint256 usdtReserve = isWbtcToken0 ? uint256(reserve1) : uint256(reserve0);
        
        // Calculate expected USDT output based on Uniswap's pricing formula
        uint256 usdtExpected = getAmountOut(wbtcAmount, wbtcReserve, usdtReserve);
        
        // First transfer WBTC to the pair contract
        IERC20(WBTC).transfer(wbtcUsdtPair, wbtcAmount);
        // Then call swap() with the correct parameter order based on token positions
        if (isWbtcToken0) {
            IUniswapV2Pair(wbtcUsdtPair).swap(0, usdtExpected, address(this), "");
        } else {
            IUniswapV2Pair(wbtcUsdtPair).swap(usdtExpected, 0, address(this), "");
        }
        return usdtExpected;
    }

    // Helper function for swapping WBTC to WETH
    function swapWbtcToWeth(uint256 wbtcAmount) internal returns (uint256) {
        // Get current reserves (liquidity) from the WBTC-WETH pool
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(wbtcWethPair).getReserves();
        
        // Calculate expected WETH output based on Uniswap's pricing formula
        uint256 wethExpected = getAmountOut(
            wbtcAmount,
            isWbtcToken0InWbtcWethPair ? reserve0 : reserve1,
            isWbtcToken0InWbtcWethPair ? reserve1 : reserve0
        );
        
        // First transfer WBTC to the pair contract
        IERC20(WBTC).transfer(wbtcWethPair, wbtcAmount);
        // Then call swap() with the correct parameter order based on token positions
        if (isWbtcToken0InWbtcWethPair) {
            IUniswapV2Pair(wbtcWethPair).swap(0, wethExpected, address(this), "");
        } else {
            IUniswapV2Pair(wbtcWethPair).swap(wethExpected, 0, address(this), "");
        }
        return wethExpected;
    }

    // Helper function for swapping in Curve
    function swapInCurve(
        address tokenIn,
        int128 indexIn,
        int128 indexOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256) {
        // Get initial balance of token we're receiving
        address tokenOut = indexOut == CURVE_USDT_INDEX ? USDT : USDC;
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        
        // Approve Curve pool
        IERC20(tokenIn).approve(CURVE_3POOL, 0);
        IERC20(tokenIn).approve(CURVE_3POOL, amountIn);
        
        // Execute swap
        ICurvePool(CURVE_3POOL).exchange(
            indexIn,
            indexOut,
            amountIn,
            minAmountOut
        );
        
        // Calculate amount received by checking balance difference
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountReceived = balanceAfter - balanceBefore;
        
        require(amountReceived >= minAmountOut, "Curve: Insufficient output amount");
        return amountReceived;
    }

    // Helper function for liquidating the target user
    function performLiquidation(uint256 usdtAmount) internal returns (uint256) {
        IERC20(USDT).approve(AAVE_LENDING_POOL, usdtAmount);
        ILendingPool(AAVE_LENDING_POOL).liquidationCall(
            WBTC,
            USDT,
            TARGET_USER,
            usdtAmount,
            false
        );
        return IERC20(WBTC).balanceOf(address(this));
    }
    
    // required by the swap
    function uniswapV2Call(
        address,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override {
        require(msg.sender == usdcWethPair, "Callback not from USDC-WETH pair");

        // Get borrowed USDC amount
        uint256 usdcAmount = isUsdcToken0InUsdcWethPair ? amount0 : amount1;
        uint256 usdcToRepay = (usdcAmount * 1000) / 997 + 1;

        // Swap USDC to USDT using Curve
        uint256 expectedUsdt = ICurvePool(CURVE_3POOL).get_dy(
            CURVE_USDC_INDEX,
            CURVE_USDT_INDEX,
            usdcAmount
        );
        
        uint256 minUsdt = (expectedUsdt * 99) / 100;  // 1% slippage
        uint256 usdtReceived = swapInCurve(
            USDC,
            CURVE_USDC_INDEX,
            CURVE_USDT_INDEX,
            usdcAmount,
            minUsdt
        );

        // 2.1 liquidate the target user
        uint256 wbtcReceived = performLiquidation(usdtReceived);

        // 2.2 swap WBTC for other things or repay directly
        // Calculate how much WETH we need to get enough USDC to repay the flash loan
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(usdcWethPair).getReserves();
        uint256 wethNeeded = getAmountIn(
            usdcToRepay,
            isUsdcToken0InUsdcWethPair ? uint256(reserve1) : uint256(reserve0),
            isUsdcToken0InUsdcWethPair ? uint256(reserve0) : uint256(reserve1)
        );
        
        // Add 0.5% buffer to wethNeeded for safety
        wethNeeded = (wethNeeded * 1005) / 1000;
        
        // Calculate how much WBTC we need to swap to get that WETH
        (reserve0, reserve1, ) = IUniswapV2Pair(wbtcWethPair).getReserves();
        uint256 wbtcForRepay = getAmountIn(
            wethNeeded,
            isWbtcToken0InWbtcWethPair ? uint256(reserve0) : uint256(reserve1),
            isWbtcToken0InWbtcWethPair ? uint256(reserve1) : uint256(reserve0)
        );
        
        require(wbtcForRepay < wbtcReceived, "Liquidation not profitable");

        // Swap WBTC for WETH
        IERC20(WBTC).approve(wbtcWethPair, wbtcForRepay);
        uint256 wethReceived = swapWbtcToWeth(wbtcForRepay);

        // 2.3 repay

        // Transfer WETH to the pair - this will be used to complete the flash loan
        IERC20(WETH).transfer(usdcWethPair, wethReceived);

        // Handle remaining WBTC as profit
        uint256 wbtcForProfit = wbtcReceived - wbtcForRepay;
        if (wbtcForProfit > 0) {
            IERC20(WBTC).approve(wbtcWethPair, wbtcForProfit);
            wethReceived = swapWbtcToWeth(wbtcForProfit);
        }
    }
}