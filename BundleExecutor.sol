//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

pragma experimental ABIEncoderV2;
import "./access/Ownable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./flashloan/base/FlashLoanSimpleReceiverBase.sol";
import "./interfaces/IPoolAddressesProvider.sol";

contract UniArbMultiCall is Ownable, FlashLoanSimpleReceiverBase {
    IWETH private constant WETH =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    constructor(address initialOwner, address _poolAddressesProvider)
        payable
        FlashLoanSimpleReceiverBase(
            IPoolAddressesProvider(_poolAddressesProvider)
        )
        Ownable(initialOwner)
    {
        if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
        }
    }

    function getReservesByPair(address _pairAddress)
        external
        view
        returns (
            uint256 reserve0,
            uint256 reserve1,
            uint256 blockTimestampLast
        )
    {
        IUniswapV2Pair pair = IUniswapV2Pair(_pairAddress);
        (reserve0, reserve1, blockTimestampLast) = pair.getReserves();
    }

    receive() external payable {}

    function receiveTokens(address _tokenAddress, uint256 _amount) public {
        require(_amount > 0, "Amount must be greater than zero");

        IERC20 token = IERC20(_tokenAddress);

        require(
            token.balanceOf(msg.sender) >= _amount,
            "Insufficient token balance"
        );

        bool _success = token.transferFrom(msg.sender, address(this), _amount);
        require(_success, "Token transfer failed");
    }

    // Function to perform Uniswap arbitrage and handle WETH to Ether conversions
    function uniswapWeth(
        uint256 _wethAmountToFirstMarket,
        uint256 _ethAmountToCoinbase,
        address[] memory _targets,
        bytes[] memory _payloads
    ) external payable onlyOwner {
        require(_targets.length == _payloads.length);

        uint256 _wethBalanceBefore = WETH.balanceOf(address(this));

        uint256 _wethNeeded = _wethAmountToFirstMarket > _wethBalanceBefore
            ? _wethAmountToFirstMarket - _wethBalanceBefore
            : 0;

        if (_wethNeeded > 0) {
            // Request the flash loan
            bytes memory params = abi.encode(
                _wethBalanceBefore,
                _wethAmountToFirstMarket,
                _ethAmountToCoinbase,
                _targets,
                _payloads
            );
            // Request the flash loan
            fn_RequestFlashLoan(address(WETH), _wethNeeded, params);
        } else {
            _executeTargets(_wethAmountToFirstMarket, _targets, _payloads);

            uint256 _wethBalanceAfter = WETH.balanceOf(address(this));

            // Ensure that the WETH balance after the operation is sufficient
            require(
                _wethBalanceAfter > _wethBalanceBefore + _ethAmountToCoinbase
            );

            _settleEth(_ethAmountToCoinbase);
        }
    }

    function fn_RequestFlashLoan(
        address _token,
        uint256 _amount,
        bytes memory _params
    ) internal {
        address receiverAddress = address(this);
        address asset = _token;
        uint256 amount = _amount;
        uint16 referralCode = 0;

        POOL.flashLoanSimple(
            receiverAddress,
            asset,
            amount,
            _params,
            referralCode
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(initiator == msg.sender, "Unauthorized initiator");

        uint256 totalAmount = amount + premium;

        (
            uint256 _wethBalanceBefore,
            uint256 _wethAmountToFirstMarket,
            uint256 _ethAmountToCoinbase,
            address[] memory _targets,
            bytes[] memory _payloads
        ) = abi.decode(params, (uint256, uint256, uint256, address[], bytes[]));

        _executeTargets(_wethAmountToFirstMarket, _targets, _payloads);

        uint256 _wethBalanceAfter = WETH.balanceOf(address(this));

        // Ensure that the WETH balance after the operation is sufficient
        require(
            _wethBalanceAfter >
                _wethBalanceBefore + _ethAmountToCoinbase + totalAmount
        );

        _settleEth(_ethAmountToCoinbase);

        IERC20(asset).approve(address(POOL), totalAmount);

        return true;
    }

    function _executeTargets(
        uint256 _wethAmountToFirstMarket,
        address[] memory _targets,
        bytes[] memory _payloads
    ) internal {
        WETH.transfer(_targets[0], _wethAmountToFirstMarket);
        for (uint256 i = 0; i < _targets.length; i++) {
            (bool _success, bytes memory _response) = _targets[i].call(
                _payloads[i]
            );
            require(_success, "Swap Call failed");
            _response;
        }
    }

    function _settleEth(uint256 _ethAmountToCoinbase) internal {
        if (_ethAmountToCoinbase == 0) return;

        uint256 _ethBalance = address(this).balance;
        if (_ethBalance < _ethAmountToCoinbase) {
            uint256 _wethToWithdraw = _ethAmountToCoinbase - _ethBalance;
            WETH.withdraw(_wethToWithdraw);
        }
        payable(block.coinbase).transfer(_ethAmountToCoinbase);
    }

    function transferEther(address payable _to, uint256 _amount)
        external
        payable
        onlyOwner
    {
        require(_to != address(0), "Recipient address cannot be zero");
        require(_amount > 0, "Amount must be greater than zero");
        require(
            address(this).balance >= _amount,
            "Insufficient contract balance"
        );
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Failed to send Ether");
    }

    // 转账ERC-20代币给指定账户
    function transferToken(
        address _tokenAddress,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "Recipient address cannot be zero");
        IERC20 token = IERC20(_tokenAddress);
        bool success = token.transfer(_to, _amount);
        require(success, "Token transfer failed");
    }

    function call(
        address payable _to,
        uint256 _value,
        bytes calldata _data
    ) external payable onlyOwner returns (bytes memory) {
        require(_to != address(0));
        (bool _success, bytes memory _result) = _to.call{value: _value}(_data);
        require(_success, "Call execution failed");
        return _result;
    }
}
