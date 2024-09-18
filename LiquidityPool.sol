// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityPool {
    // ERC20 token state variables
    IERC20 public immutable token1;
    IERC20 public immutable token2;
    // State variables for token reserves
    uint256 public reserve1;
    uint256 public reserve2;
    // State variables for liquidity shares
    uint256 public totalLiquidity;
    mapping(address => uint256) public userLiquidity;

    // Events
    event MintLpToken(
        address indexed _liquidityProvider,
        uint256 _sharesMinted
    );

    event BurnLpToken(
        address indexed _liquidityProvider,
        uint256 _sharesBurned
    );

    constructor(address _token1, address _token2) {
        token1 = IERC20(_token1);
        token2 = IERC20(_token2);
    }

    // Function to get the price of token1 in terms of token2
    function getPrice()
        public
        view
        returns (uint256 _price)
    {
        if (reserve1 == 0) {
            return 0;
        }
        _price = 1e18 * reserve2 / reserve1;
    }

    // Function to get the amount of token1 for a given amount of token2, and the impact on the price
    function getBuyStats(uint256 _amountIn)
        public
        view
        returns (uint256 _amountOut, uint256 _newPrice)
    {
        // If there's no reserve, return 0
        if (reserve1 == 0 || reserve2 == 0) {
            return (0, 0);
        }
        // Calculate tokenIn with fee of 5%
        uint256 _amountInWithFee = (_amountIn * 950) / 1000;
        _amountOut =
            (reserve1 * _amountInWithFee) /
            (reserve2 + _amountInWithFee);
        _newPrice = 1e18 * (reserve2 + _amountIn) / (reserve1 - _amountOut);
    }

    // Function to get the amount of token2 for a given amount of token1, and the impact on the price
    function getSellStats(uint256 _amountIn)
        public
        view
        returns (uint256 _amountOut, uint256 _newPrice)
    {
        // If there's no reserve, return 0
        if (reserve1 == 0 || reserve2 == 0) {
            return (0, 0);
        }
        // Calculate tokenIn with fee of 5%
        uint256 _amountInWithFee = (_amountIn * 950) / 1000;
        _amountOut =
            (reserve2 * _amountInWithFee) /
            (reserve1 + _amountInWithFee);
        _newPrice = 1e18 * (reserve2 - _amountOut) / (reserve1 + _amountIn);
    }

    // Internal function to mint liquidity shares
    function _mint(address _to, uint256 _amount) private {
        userLiquidity[_to] += _amount;
        totalLiquidity += _amount;
    }

    // Internal function to burn liquidity shares
    function _burn(address _from, uint256 _amount) private {
        userLiquidity[_from] -= _amount;
        totalLiquidity -= _amount;
    }

    // Internal function to update liquidity pool reserves
    function _update(uint256 _reserve1, uint256 _reserve2) private {
        reserve1 = _reserve1;
        reserve2 = _reserve2;
    }

    // Function to buy token1 using token2
    function buy(uint256 _amountIn)
        external
        returns (uint256 _amountOut)
    {
        // Transfer tokenIn to the liquity pool
        require(_amountIn > 0, "Insufficient Amount");
        token2.transferFrom(msg.sender, address(this), _amountIn);

        // Calculate tokenIn with fee of 5%
        uint256 _amountInWithFee = (_amountIn * 950) / 1000;

        /*
        Calculate tokenOut amount using x * y = k
        > (x + dx) * (y + dy) = k`
        > y - dy = (xy) / (x + dx)
        > dy = y - ((xy) / (x + dx))
        > dy = y * (1 - (x / (x + dx)))
        > dy = y * (((x + dx) / (x + dx)) - (x / (x + dx)))
        > dy = y * (dx / (x + dx))
        ~~~ dy = (y * dx) / (x + dx) ~~~
        */
        _amountOut =
            (reserve1 * _amountInWithFee) /
            (reserve2 + _amountInWithFee);

        require(_amountOut < reserve1, "Insufficient Liquidity");

        // Transfer tokenOut to the user
        token1.transfer(msg.sender, _amountOut);

        // Update the reserves
        _update(
            token1.balanceOf(address(this)),
            token2.balanceOf(address(this))
        );
    }

    // Function to sell token1 and get token2
    function sell(uint256 _amountIn)
        external
        returns (uint256 _amountOut)
    {
        // Transfer tokenIn to the liquity pool
        require(_amountIn > 0, "Insufficient Amount");
        token1.transferFrom(msg.sender, address(this), _amountIn);

        // Calculate tokenIn with fee of 5%
        uint256 _amountInWithFee = (_amountIn * 950) / 1000;

        /*
        Calculate tokenOut amount using x * y = k
        > (x + dx) * (y + dy) = k`
        > y - dy = (xy) / (x + dx)
        > dy = y - ((xy) / (x + dx))
        > dy = y * (1 - (x / (x + dx)))
        > dy = y * (((x + dx) / (x + dx)) - (x / (x + dx)))
        > dy = y * (dx / (x + dx))
        ~~~ dy = (y * dx) / (x + dx) ~~~
        */
        _amountOut =
            (reserve2 * _amountInWithFee) /
            (reserve1 + _amountInWithFee);

        require(_amountOut < reserve2, "Insufficient Liquidity");

        // Transfer tokenOut to the user
        token2.transfer(msg.sender, _amountOut);

        // Update the reserves
        _update(
            token1.balanceOf(address(this)),
            token2.balanceOf(address(this))
        );
    }

    // Function for user to add liquidity
    function addLiquidity(uint256 _amountToken1, uint256 _amountToken2)
        external
        returns (uint256 _liquidityShares)
    {
        // User sends both tokens to liquidity pool
        require(
            token1.transferFrom(msg.sender, address(this), _amountToken1),
            "Token Transfer Failed"
        );
        require(
            token2.transferFrom(msg.sender, address(this), _amountToken2),
            "Token Transfer Failed"
        );

        /*
        Check if the ratio of tokens supplied is proportional
        to reserve ratio to satisfy x * y = k for price to not
        change if both reserves are greater than 0
        */
        if (reserve1 > 0 || reserve2 > 0) {
            require(
                _amountToken1 * reserve2 == _amountToken2 * reserve1,
                "Unbalanced Liquidity Provided"
            );
        }

        /*
        Calculate number of liquidity shares to mint using
        the geometric mean as a measure of liquidity. Increase
        in liquidity is proportional to increase in shares
        minted.
        > S = (dx / x) * TL
        > S = (dy / y) * TL
        NOTE: Amount of liquidity shares minted formula is similar
        to Uniswap V2 formula. For minting liquidity shares, we take
        the minimum of the two values calculated to incentivize depositing
        balanced liquidity.
        */
        uint256 _totalLiquidity = totalLiquidity;

        if (_totalLiquidity == 0) {
            _liquidityShares = sqrt(_amountToken1 * _amountToken2);
        } else {
            _liquidityShares = min(
                ((_amountToken1 * _totalLiquidity) / reserve1),
                ((_amountToken2 * _totalLiquidity) / reserve2)
            );
        }

        require(_liquidityShares > 0, "No Liquidity Shares Minted");
        // Mint shares to user
        _mint(msg.sender, _liquidityShares);

        // Update the reserves
        _update(
            token1.balanceOf(address(this)),
            token2.balanceOf(address(this))
        );

        emit MintLpToken(msg.sender, _liquidityShares);
    }

    /*
    Function for user to remove liquidity
    > dx = (S / TL) * x
    > dy = (S / TL) * y
    */
    function removeLiquidity(uint256 _liquidityShares)
        external
        returns (uint256 _amountToken1, uint256 _amountToken2)
    {
        require(
            userLiquidity[msg.sender] >= _liquidityShares,
            "Insufficient liquidity shares"
        );
        // Get balance of both tokens
        uint256 token1Balance = token1.balanceOf(address(this));
        uint256 token2Balance = token2.balanceOf(address(this));

        uint256 _totalLiquidity = totalLiquidity;

        _amountToken1 = (_liquidityShares * token1Balance) / _totalLiquidity;
        _amountToken2 = (_liquidityShares * token2Balance) / _totalLiquidity;

        require(
            _amountToken1 > 0 && _amountToken2 > 0,
            "Insufficient transfer amounts"
        );

        // Burn user liquidity shares
        _burn(msg.sender, _liquidityShares);

        // Update reserves
        _update(token1Balance - _amountToken1, token2Balance - _amountToken2);

        // Transfer tokens to user
        token1.transfer(msg.sender, _amountToken1);
        token2.transfer(msg.sender, _amountToken2);

        emit BurnLpToken(msg.sender, _liquidityShares);
    }

    // Internal function to square root a value from Uniswap V2
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // Internal function to find minimum value from Uniswap V2
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }
}