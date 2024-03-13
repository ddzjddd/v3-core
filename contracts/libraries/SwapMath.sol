// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        //在A换B的情况下，在池子的角度，指定精确的A数量，是入池子，所以叫做exactIn模式；如果是指定精确的B数量，是出池子，所以叫exactOut模式。
        //入池子的数量在池子看来是增，所以是正数；出池子的数量在池子看来是减，所以是负数。
        bool exactIn = amountRemaining >= 0;
        //在精确指定入池子数量的情况下，要依据精确指定的数量进行后续的计算
        if (exactIn) {
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            //如果是x换y，则计算x的在指定价格变动跨度后，消耗的x的数量
            //如果是y换x，则计算y的在指定价格变动跨度后，消耗的y的数量
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            //如果在上述价格区间内，无法消耗完用户指定的数量，则要进入到下一头寸区间继续进行swap操作；更新本次交换完后，x的价格情况（合约中只存储x的价格，这里价格的含义是每单位x等价于多少y，就是以y作为基本衡量单位）
            if (amountRemainingLessFee >= amountIn) sqrtRatioNextX96 = sqrtRatioTargetX96;
            //如果能够消耗完用户指定的数量，则计算恰好消耗完用户指定的数量会使价格达到什么值
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
        } else {
            //精确指定出池子数量与上述不同之处在于，要依据用户指定的输出数量来进行后续的计算
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }
        //判断价格是否达到头寸边界的价格
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        if (zeroForOne) {
            //如果达到了头寸边界的价格并且是exactIn模式，则以前序计算出来的amountIn为准
            //其他情况，比如没有达到边界价格，那么前面计算出来的amountIn是偏大的，以为是以边界价格来计算的；比如不是exactIn模型，那前序根本就没有计算amountIn的值。所以要重新计算amoutIn的值，依据交换完后的实际价格来计算amountIn数量
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            //如果达到了头寸边界的价格并且是exactOut模式，则以前序计算出来的amountOut为准
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            //与前一分支的区别在于，前面是x换y，这里是y换x（x对应getAmount0Delta，y对应getAmount1Delta）
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        //控制计算出来的出池子的数量不能超过用户指定的数量
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        //如果在当前头寸区间已经完成交换，那针对计算出来的入池数量与用户指定数量之间的差值（因为入池的实际数量会向下取整，使得实际入池的数量小于等于用户指定的数量，但是在扣除用户的入池代币数量时，又是按照用户指定数量transfer的），作为手续费
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
