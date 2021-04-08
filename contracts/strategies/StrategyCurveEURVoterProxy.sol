// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.5.17;

import "@openzeppelinV2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV2/contracts/math/SafeMath.sol";
import "@openzeppelinV2/contracts/utils/Address.sol";
import "@openzeppelinV2/contracts/token/ERC20/SafeERC20.sol";

import "../../interfaces/yearn/IController.sol";
import "../../interfaces/curve/Gauge.sol";
import "../../interfaces/curve/Mintr.sol";
import "../../interfaces/uniswap/Uni.sol";
import "../../interfaces/curve/Curve.sol";
import "../../interfaces/yearn/IVoterProxy.sol";

contract StrategyCurveEURVoterProxy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant want = address(0x194eBd173F6cDacE046C53eACcE9B953F28411d1);
    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);

    address public constant curve = address(0x0Ce6a5fF5217e38315f87032CF90686C96627CAA);
    address public constant gauge = address(0x90Bb609649E0451E5aD952683D64BD2d1f245840);
    address public constant voter = address(0xF147b8125d2ef93FB6965Db97D6746952a133934);

    address public constant eurs = address(0xdB25f211AB05b1c97D595516F45794528a807ad8);
    address public constant usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // used for crv <> weth <> usdc <> eurs route

    uint256 public keepCRV = 500;
    uint256 public treasuryFee = 1000;
    uint256 public strategistReward = 1000;
    uint256 public withdrawalFee = 0;
    uint256 public constant FEE_DENOMINATOR = 10000;

    address public proxy;
    address public dex;

    address public governance;
    address public controller;
    address public strategist;
    address public keeper;

    uint256 public earned; // lifetime strategy earnings denominated in `want` token

    event Harvested(uint256 wantEarned, uint256 lifetimeEarned);

    constructor(address _controller) public {
        governance = msg.sender;
        strategist = msg.sender;
        keeper = msg.sender;
        controller = _controller;
        // standardize constructor
        proxy = address(0xC17ADf949f524213a540609c386035D7D685B16F);
        dex = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    }

    function getName() external pure returns (string memory) {
        return "StrategyCurveEURVoterProxy";
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        strategist = _strategist;
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        keeper = _keeper;
    }

    function setKeepCRV(uint256 _keepCRV) external {
        require(msg.sender == governance, "!governance");
        keepCRV = _keepCRV;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        require(msg.sender == governance, "!governance");
        withdrawalFee = _withdrawalFee;
    }

    function setTreasuryFee(uint256 _treasuryFee) external {
        require(msg.sender == governance, "!governance");
        treasuryFee = _treasuryFee;
    }

    function setStrategistReward(uint256 _strategistReward) external {
        require(msg.sender == governance, "!governance");
        strategistReward = _strategistReward;
    }

    function setProxy(address _proxy) external {
        require(msg.sender == governance, "!governance");
        proxy = _proxy;
    }

    function deposit() public {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeTransfer(proxy, _want);
            IVoterProxy(proxy).deposit(gauge, want);
        }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        require(crv != address(_asset), "crv");
        require(eurs != address(_asset), "eurs");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a vault withdrawal
    function withdraw(uint256 _amount) external {
        require(msg.sender == controller, "!controller");
        uint256 _balance = IERC20(want).balanceOf(address(this));
        if (_balance < _amount) {
            _amount = _withdrawSome(_amount.sub(_balance));
            _amount = _amount.add(_balance);
        }

        uint256 _fee = _amount.mul(withdrawalFee).div(FEE_DENOMINATOR);

        IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        return IVoterProxy(proxy).withdraw(gauge, want, _amount);
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        _withdrawAll();

        balance = IERC20(want).balanceOf(address(this));

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
        IVoterProxy(proxy).withdrawAll(gauge, want);
    }

    function harvest() public {
        require(msg.sender == keeper || msg.sender == strategist || msg.sender == governance, "!keepers");
        IVoterProxy(proxy).harvest(gauge);
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            uint256 _keepCRV = _crv.mul(keepCRV).div(FEE_DENOMINATOR);
            IERC20(crv).safeTransfer(voter, _keepCRV);
            _crv = _crv.sub(_keepCRV);

            IERC20(crv).safeApprove(dex, 0);
            IERC20(crv).safeApprove(dex, _crv);

            address[] memory path = new address[](4);
            path[0] = crv;
            path[1] = weth;
            path[2] = usdc;
            path[3] = eurs;

            Uni(dex).swapExactTokensForTokens(_crv, uint256(0), path, address(this), now.add(1800));
        }
        uint256 _eurs = IERC20(eurs).balanceOf(address(this));
        if (_eurs > 0) {
            IERC20(eurs).safeApprove(curve, 0);
            IERC20(eurs).safeApprove(curve, _eurs);
            ICurveFi(curve).add_liquidity([_eurs, 0], 0);
        }
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            uint256 _fee = _want.mul(treasuryFee).div(FEE_DENOMINATOR);
            uint256 _reward = _want.mul(strategistReward).div(FEE_DENOMINATOR);
            IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
            IERC20(want).safeTransfer(strategist, _reward);
            deposit();
        }
        IVoterProxy(proxy).lock();
        earned = earned.add(_want);
        emit Harvested(_want, earned);
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return IVoterProxy(proxy).balanceOf(gauge);
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setController(address _controller) external {
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }
}
