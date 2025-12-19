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
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
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

    function token0() external view returns (address);
    function token1() external view returns (address);
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

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    // END TODO
    address public constant AAVE_LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;//pool
    address public constant TARGET_USER = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;//user
    address public constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    //ILendingPool constant lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    IERC20 public constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7); // 显式声明IERC20
    IERC20 public constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599); // 显式声明IERC20
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // 显式声明IWETH
 
    uint debt_USDT;//声明债务

    ILendingPool public immutable lendingPool;
    IUniswapV2Pair public immutable uniswapV2Pair_WETH_USDT; // Pool1
    IUniswapV2Pair public immutable uniswapV2Pair_WBTC_WETH; // Pool2
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
        //   *** Your code here ***
        // END TODO
        lendingPool = ILendingPool(AAVE_LENDING_POOL);
        uniswapV2Pair_WETH_USDT = IUniswapV2Pair(IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(address(WETH), address(USDT)));
        uniswapV2Pair_WBTC_WETH = IUniswapV2Pair(IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(address(WBTC), address(WETH)));
        debt_USDT=2000000 * 10**6;
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    // END TODO
    receive() external payable {}
    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***
        require(msg.sender != address(0), "LiquidationOperator: INVALID_SENDER");
        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        uint256 totalCollateralETH;
        uint256 totalDebtETH;
        uint256 availableBorrowsETH;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
        (
            totalCollateralETH,
            totalDebtETH,
            availableBorrowsETH,
            currentLiquidationThreshold,
            ltv,
            healthFactor
        ) = lendingPool.getUserAccountData(TARGET_USER);
        console.log("Target user health factor:", healthFactor);
        require(healthFactor < 1 ether, "LiquidationOperator: USER_NOT_LIQUIDATABLE");
        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***
        bytes memory flashLoanData = abi.encode(msg.sender);
        uniswapV2Pair_WETH_USDT.swap(
            0, // 不借 token0（WETH）
            debt_USDT, // 借 debt_USDT 数量的 token1（USDT）
            address(this), // 本合约接收 USDT
            flashLoanData // 传递利润接收者地址
        );
        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***

        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        require(msg.sender == address(uniswapV2Pair_WETH_USDT),"LiquidationOperator: ONLY_WETH_USDT_PAIR");
        require(sender == address(this),"LiquidationOperator: ONLY_SELF_TRIGGER");
        require(amount0 == 0 && amount1 > 0,"LiquidationOperator: WRONG_FLASHLOAN_ASSET");
        address profitReceiver = abi.decode(data, (address));
        require(profitReceiver != address(0),"LiquidationOperator: INVALID_PROFIT_RECEIVER");
        
        
        // 2.1 liquidate the target user
        //    *** Your code here ***
        USDT.approve(address(lendingPool), amount1);
        
        console.log("USDT balance before liquidation:", USDT.balanceOf(address(this)));

        lendingPool.liquidationCall(address(WBTC), address(USDT), TARGET_USER,amount1, false);

        uint256 receivedWBTC = WBTC.balanceOf(address(this));
        console.log("Received WBTC from liquidation:", receivedWBTC); 
        require(receivedWBTC > 0,"LiquidationOperator: NO_WBTC_FROM_LIQUIDATION");
        
        
        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        uint256 swapWETHOut = _swapWBTCToWETH(receivedWBTC);
        require(swapWETHOut > 0, "LiquidationOperator: INSUFFICIENT_WETH_OUTPUT");
        
        // 2.3 repay
        //    *** Your code here ***
        _repayFlashLoan(amount1, profitReceiver);
    }

    function _swapWBTCToWETH(uint256 receivedWBTC) internal returns (uint256) {
        bool isWBTCtoken0 = (uniswapV2Pair_WBTC_WETH.token0() == address(WBTC));
        console.log("Is WBTC token0 in WBTC-WETH pair?", isWBTCtoken0);
        
        (uint112 reserveWBTC, uint112 reserveWETH, ) = uniswapV2Pair_WBTC_WETH.getReserves();
        if (!isWBTCtoken0) (reserveWBTC, reserveWETH) = (reserveWETH, reserveWBTC);
        
        // 每次兑换不超过储备金的 5%，避免滑点过大
        uint256 maxPerSwap = uint256(reserveWBTC) * 5 / 100; // 5% 储备金
        uint256 remaining = receivedWBTC;
        uint256 totalWETH;
        while (remaining > 0) {
            uint256 swapAmount = remaining < maxPerSwap ? remaining : maxPerSwap;
            uint256 wethOut = getAmountOut(swapAmount, uint256(reserveWBTC), uint256(reserveWETH));
            
            WBTC.approve(address(uniswapV2Pair_WBTC_WETH), swapAmount);
            WBTC.transfer(address(uniswapV2Pair_WBTC_WETH), swapAmount);
            
            if (isWBTCtoken0) {
                uniswapV2Pair_WBTC_WETH.swap(0, wethOut, address(this), new bytes(0));
            } else {
                uniswapV2Pair_WBTC_WETH.swap(wethOut, 0, address(this), new bytes(0));
            }
            
            totalWETH += wethOut;
            remaining -= swapAmount;
            
            // 更新储备金（避免重复计算导致的误差）
            (reserveWBTC, reserveWETH, ) = uniswapV2Pair_WBTC_WETH.getReserves();
            if (!isWBTCtoken0) (reserveWBTC, reserveWETH) = (reserveWETH, reserveWBTC);
        }
        return totalWETH;
    }

    function _repayFlashLoan(uint256 amount1, address profitReceiver) internal {
        // 计算需偿还的 USDT（含手续费）
        uint256 usdtToRepay = amount1;
        console.log("USDT to repay (with fee):", usdtToRepay);

        // 计算所需 WETH 数量
        bool isWETHToken0 = (uniswapV2Pair_WETH_USDT.token0() == address(WETH));
        (uint112 reserveWETH, uint112 reserveUSDT, ) = uniswapV2Pair_WETH_USDT.getReserves();
        if (!isWETHToken0) (reserveWETH, reserveUSDT) = (reserveUSDT, reserveWETH);
        
        uint256 wethToRepay = getAmountIn(usdtToRepay, uint256(reserveWETH), uint256(reserveUSDT));
        require(wethToRepay > 0, "LiquidationOperator: INSUFFICIENT_WETH_TO_REPAY");
        console.log("WETH needed to repay:", wethToRepay);

        // 3. 确保 WETH 余额足够
        uint256 currentWETH = WETH.balanceOf(address(this));
        require(currentWETH >= wethToRepay, "LiquidationOperator: NOT_ENOUGH_WETH");

        // 4. 直接转移 WETH 到 WETH-USDT 交易对完成偿还（无 swap 调用）
        WETH.approve(address(uniswapV2Pair_WETH_USDT), wethToRepay);
        bool wethRepaySuccess = WETH.transfer(address(uniswapV2Pair_WETH_USDT), wethToRepay);
        require(wethRepaySuccess, "LiquidationOperator: WETH_REPAY_FAILED");
        console.log("WETH repaid to pair:", wethToRepay);

        // 5. 转移剩余利润（WETH 转 ETH）
        uint256 remainingWETH = WETH.balanceOf(address(this));
        if (remainingWETH > 0) {
            WETH.withdraw(remainingWETH);
            (bool success, ) = profitReceiver.call{value: remainingWETH}("");
            require(success, "LiquidationOperator: PROFIT_TRANSFER_FAILED");
        }
    }
}

