// SPDX-License-Identifier: MIT
/*
This is a Stacker.vc VC Treasury version 1 contract. It initiates a 3 year VC Fund that makes investments in ETH, and tries to sell previously acquired ERC20's at a profit.
This fund also has veto functionality by SVC001 token holders. A token holder can stop all buys and sells OR even close the fund early.
*/

pragma solidity ^0.6.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol"; // call ERC20 safely
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../Interfaces/IMinter.sol";

contract VCTreasuryV1 is ERC20 {
	using SafeERC20 for IERC20;
	using Address for address;
    using SafeMath for uint256;

	address public advisoryMultisig;
	address public deployer;
	address public treasury;

	enum FundStates {setup, active, paused, closed}
	FundStates public currentState;

	uint256 public fundStartTime;
	uint256 public fundCloseTime;

	uint256 public totalStakedToPause;
	uint256 public totalStakedToKill;

	mapping(address => uint256) stakedToPause;
	mapping(address => uint256) stakedToKill;

	// fixed once set
	uint256 public initETH;
	uint256 public constant investmentCap = 10; // percentage of initETH that can be invested of "max"
	uint256 public maxInvestment;

	uint256 public constant pauseQuorum = 30; // must be over this percent for a pause to take effect (of "max")
	uint256 public constant killQuorum = 50; // must be over this percent for a kill to take effect (of "max")
	uint256 public constant max = 100;

	// used to determine total amount invested in last 30 days
	uint256 public currentInvestmentUtilization;
	uint256 public lastInvestTime;

	uint256 public constant THREE_YEARS = 94608000; // 3 years * 365 days * 24 hours * 60 minutes * 60 seconds = 94,608,000
	uint256 public constant ONE_YEAR = 31536000; // 365 days * 24 hours * 60 minutes * 60 seconds = 31,536,000
	uint256 public constant THIRTY_DAYS = 2592000; // 30 days * 24 hours * 60 minutes * 60 seconds = 2,592,000
	uint256 public constant THREE_DAYS = 259200; // 3 days * 24 hours * 60 minutes * 60 seconds = 259,200
	uint256 public constant ONE_WEEK = 604800; // 7 days * 24 hours * 60 minutes * 60 seconds = 604,800

	struct BuyProposal {
		uint256 buyId;
		address tokenAccept;
		uint256 amountInMin;
		uint256 ethOut;
		address taker;
		uint256 maxTime;
	}

	BuyProposal public currentBuyProposal; // only one buy proposal at a time, unlike sells
	uint256 nextBuyId;
	mapping(address => bool) boughtTokens; // a list of all tokens purchased (executed successfully)

	struct SellProposal {
		address tokenSell;
		uint256 ethInMin;
		uint256 amountOut;
		address taker;
		uint256 vetoTime;
		uint256 maxTime;
	}

	mapping(uint256 => SellProposal) currentSellProposals; // can have multiple sells at a time
	uint256 nextSellId;

	// fees
	uint256 public constant yearlyFee = 1;
	uint256 public constant treasuryFee = 25;
	uint256 public constant advisorFee = 75;

	bool public year1Claimed;
	bool public year2Claimed;
	bool public year3Claimed;

	event InvestmentProposed(uint256 buyId, address tokenAccept, uint256 amountInMin, uint256 amountOut, address taker, uint256 maxTime);
	event InvestmentRevoked(uint256 buyId, uint256 time);
	event InvestmentExecuted(uint256 buyId, address tokenAccept, uint256 amountIn, uint256 amountOut, address taker, uint256 time);
	event DevestmentProposed(uint256 sellId, address tokenSell, uint256 ethInMin, uint256 amountOut, address taker, uint256 vetoTime, uint256 maxTime);
	event DevestmentRevoked(uint256 sellId, uint256 time);
	event DevestmentExecuted(uint256 sellId, address tokenSell, uint256 ethIn, uint256 amountOut, address taker, uint256 time);


	constructor(address _multisig, address _treasury) public ERC20("Stacker.vc Fund001", "SVC001") {
		deployer = msg.sender;
		advisoryMultisig = _multisig;
		treasury = _treasury;

		currentState = FundStates.setup;
		
		_setupDecimals(18);
	}

	// receive ETH, do nothing
	receive() payable external {
		return;
	}

	// change the multisig account
	function setAdvisoryMultisig(address _new) external {
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		advisoryMultisig = _new;
	}

	// change deployer account, only used for setup (no need to funnel setup calls thru multisig)
	function setDeployer(address _new) external {
		require(msg.sender == advisoryMultisig || msg.sender == deployer, "TREASURYV1: !(advisoryMultisig || deployer)");

		deployer = _new;
	}

	function setTreasury(address _new) external {
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		treasury = _new;
	}

	// mark a token as bought and able to be distributed when the fund closes. this would be for some sort of airdrop or "freely" acuired token sent to the contract
	function setBoughtToken(address _new) external {
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		boughtTokens[_new] = true;
	}
	
	// mint SVC001 tokens to users, fund cannot be started. SVC001 distribution must be audited and checked before the funds is started. Cannot mint tokens after fund starts.
	function issueTokens(address[] calldata _user, uint256[] calldata _amount) external {
		require(currentState == FundStates.setup, "TREASURYV1: !FundStates.setup");
		require(msg.sender == deployer, "TREASURYV1: !deployer");
		require(_user.length == _amount.length, "TREASURYV1: length mismatch");
		require(_user.length <= 50, "TREASURYV1: length > 50"); // don't allow unbounded loops, bad design, gas issues

		for (uint256 i = 0; i < _user.length; i++){
			_mint(_user[i], _amount[i]);
		}
	}

	// seed the fund with ETH and start it up. 3 years until the fund is dissolved
	function startFund() payable external {
		require(currentState == FundStates.setup, "TREASURYV1: !FundStates.setup");
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");
		require(totalSupply() > 0, "TREASURYV1: invalid setup");

		fundStartTime = block.timestamp;
		fundCloseTime = block.timestamp.add(THREE_YEARS);

		initETH = msg.value;
		maxInvestment = msg.value.div(max).mul(investmentCap);

		_changeFundState(FundStates.active); // set fund active!
	}

	// mint SVC001 tokens to the managers/treasury, 0.25% yearly to treasury, 0.75% yearly to advisorMultisig
	// fee can be claimed one week before the year closes. fund must not be closed in order to claim fee
	// don't miss out on claiming the last years fee, if you wait > 1 week the fund will close!
	function takeYearlyFee() external {
		require(currentState == FundStates.active || currentState == FundStates.paused, "TREASURYV1: !(FundStates.active || FundStates.paused)");
		// require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig"); // NOTE: don't enforce this, a STACK holder who wants treasury fee can also claim.

		if (!year1Claimed && block.timestamp >= fundStartTime.add(ONE_YEAR).sub(ONE_WEEK)){
			_assessFee();
			year1Claimed = true;
		}

		if (!year2Claimed && block.timestamp >= fundStartTime.add(ONE_YEAR).add(ONE_YEAR).sub(ONE_WEEK)){
			_assessFee();
			year2Claimed = true;
		}

		if (!year3Claimed && block.timestamp >= fundCloseTime.sub(ONE_WEEK)){
			_assessFee();

			year3Claimed = true;
		}
	}

	function _assessFee() internal {
		uint256 _totalAmount = totalSupply().div(max).mul(yearlyFee);
		uint256 _treasuryAmount = _totalAmount.div(max).mul(treasuryFee);
		uint256 _advisorAmount = _totalAmount.sub(_treasuryAmount);

		_mint(treasury, _treasuryAmount);
		_mint(advisoryMultisig, _advisorAmount);
	}

	// make an offer invest in a project by sending ETH to the project in exchange for tokens. one investment at a time. get ERC20, give ETH
	function investPropose(address _tokenAccept, uint256 _amountInMin, uint256 _ethOut, address _taker) external {
		_checkCloseTime();
		require(currentState == FundStates.active, "TREASURYV1: !FundStates.active");
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		// checks that the investment utilization (30 day rolling average) isn't exceeded. will revert(). otherwise will update to new rolling average
		_updateInvestmentUtilization(_ethOut);

		BuyProposal memory _buy;
		_buy.buyId = nextBuyId;
		_buy.tokenAccept = _tokenAccept;
		_buy.amountInMin = _amountInMin;
		_buy.ethOut = _ethOut;
		_buy.taker = _taker;
		_buy.maxTime = block.timestamp.add(THREE_DAYS); // three days maximum to accept a buy

		currentBuyProposal = _buy;
		nextBuyId = nextBuyId.add(1);
		
		InvestmentProposed(_buy.buyId, _tokenAccept, _amountInMin, _ethOut, _taker, _buy.maxTime);
	}

	// revoke an uncompleted investment offer
	function investRevoke(uint256 _buyId) external {
		_checkCloseTime();
		require(currentState == FundStates.active || currentState == FundStates.paused, "TREASURYV1: !(FundStates.active || FundStates.paused)");
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		BuyProposal memory _buy = currentBuyProposal;
		require(_buyId == _buy.buyId, "TREASURYV1: buyId not active");

		BuyProposal memory _reset;
		currentBuyProposal = _reset;

		InvestmentRevoked(_buy.buyId, block.timestamp);
	}

	// execute an investment offer by sending tokens to the contract, in exchange for ETH
	function investExecute(uint256 _buyId, uint256 _amount) external {
		_checkCloseTime();
		require(currentState == FundStates.active, "TREASURYV1: !FundStates.active");

		BuyProposal memory _buy = currentBuyProposal;
		require(_buyId == _buy.buyId, "TREASURYV1: buyId not active");
		require(_buy.tokenAccept != address(0), "TREASURYV1: !tokenAccept");
		require(_amount >= _buy.amountInMin, "TREASURYV1: _amount < amountInMin");
		require(_buy.taker == msg.sender || _buy.taker == address(0), "TREASURYV1: !taker"); // if taker is set to 0x0, anyone can accept this investment
		require(block.timestamp <= _buy.maxTime, "TREASURYV1: time > maxTime");

		BuyProposal memory _reset;
		currentBuyProposal = _reset; // set investment proposal to a blank proposal, re-entrancy guard

		uint256 _before = IERC20(_buy.tokenAccept).balanceOf(address(this));
		IERC20(_buy.tokenAccept).safeTransferFrom(msg.sender, address(this), _amount);
		uint256 _after = IERC20(_buy.tokenAccept).balanceOf(address(this));
		require(_after.sub(_before) >= _buy.amountInMin, "TREASURYV1: received < amountInMin"); // check again to verify received amount was correct

		boughtTokens[_buy.tokenAccept] = true;

		msg.sender.transfer(_buy.ethOut); // send the ETH out 

		InvestmentExecuted(_buy.buyId, _buy.tokenAccept, _amount, _buy.ethOut, msg.sender, block.timestamp);
	}

	// allow advisory multisig to propose a new sell. get ETH, give ERC20 prior investment
	function devestPropose(address _tokenSell, uint256 _ethInMin, uint256 _amountOut, address _taker) external {
		_checkCloseTime();
		require(currentState == FundStates.active, "TREASURYV1: !FundStates.active");
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		SellProposal memory _sell;
		_sell.tokenSell = _tokenSell;
		_sell.ethInMin = _ethInMin;
		_sell.amountOut = _amountOut;
		_sell.taker = _taker;
		_sell.vetoTime = block.timestamp.add(THREE_DAYS);
		_sell.maxTime = block.timestamp.add(THREE_DAYS).add(THREE_DAYS);

		currentSellProposals[nextSellId] = _sell;
		
		DevestmentProposed(nextSellId, _tokenSell, _ethInMin, _amountOut, _taker, _sell.vetoTime, _sell.maxTime);

		nextSellId = nextSellId.add(1);
	}

	// revoke an uncompleted sell offer
	function devestRevoke(uint256 _sellId) external {
		_checkCloseTime();
		require(currentState == FundStates.active || currentState == FundStates.paused, "TREASURYV1: !(FundStates.active || FundStates.paused)");
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");
		require(_sellId < nextSellId, "TREASURYV1: !sellId");

		SellProposal memory _reset;
		currentSellProposals[_sellId] = _reset;

		DevestmentRevoked(_sellId, block.timestamp);
	}

	// execute a divestment of funds
	function devestExecute(uint256 _sellId) external payable {
		_checkCloseTime();
		require(currentState == FundStates.active, "TREASURYV1: !FundStates.active");

		SellProposal memory _sell = currentSellProposals[_sellId];
		require(_sell.tokenSell != address(0), "TREASURYV1: !tokenSell");
		require(msg.value >= _sell.ethInMin, "TREASURYV1: <ethInMin");
		require(_sell.taker == msg.sender || _sell.taker == address(0), "TREASURYV1: !taker"); // if taker is set to 0x0, anyone can accept this devestment
		require(block.timestamp > _sell.vetoTime, "TREASURYV1: time < vetoTime");
		require(block.timestamp <= _sell.maxTime, "TREASURYV1: time > maxTime");

		SellProposal memory _reset;
		currentSellProposals[_sellId] = _reset; // set devestment proposal to a blank proposal, re-entrancy guard

		// we already received msg.value >= _sell.ethInMin, by above assertions. so just transfer the ERC20 to the taker
		IERC20(_sell.tokenSell).safeTransfer(msg.sender, _sell.amountOut);

		// if we completely sell out of an asset, mark this as not owned anymore
		if (IERC20(_sell.tokenSell).balanceOf(address(this)) == 0){
			boughtTokens[_sell.tokenSell] = false;
		}

		DevestmentExecuted(_sellId, _sell.tokenSell, msg.value, _sell.amountOut, msg.sender, block.timestamp);
	}

	// stake SVC001 tokens to the fund. this signals unhappyness with the fund management
	// Pause: if 30% of SVC tokens are staked here, then all sells & buys will be disabled. They will be reenabled when tokens staked drops under 30%
	// tokens staked to stakeToKill() count as 
	function stakeToPause(uint256 _amount) external {
		_checkCloseTime();
		require(currentState == FundStates.active || currentState == FundStates.paused, "TREASURYV1: !(FundStates.active || FundStates.paused)");

		// since this contract IS the SVC001 token contract, we don't need to follow the standard approve -> transferFrom workflow
		require(balanceOf(msg.sender) >= _amount, "TREASURYV1: insufficient balance to stakeToPause");
		_transfer(msg.sender, address(this), _amount);

		stakedToPause[msg.sender] = stakedToPause[msg.sender].add(_amount);
		totalStakedToPause = totalStakedToPause.add(_amount);

		_updateFundStateAfterStake();
	}

	// Kill: if 50% of SVC tokens are staked here, then the fund will close, and assets will be retreived
	// if 30% of tokens are staked here, then the fund will be paused. See above stakeToPause()
	function stakeToKill(uint256 _amount) external {
		_checkCloseTime();
		require(currentState == FundStates.active || currentState == FundStates.paused, "TREASURYV1: !(FundStates.active || FundStates.paused)");
		require(balanceOf(msg.sender) >= _amount, "TREASURYV1: insufficient balance to stakeToKill");

		_transfer(msg.sender, address(this), _amount);

		stakedToKill[msg.sender] = stakedToKill[msg.sender].add(_amount);
		totalStakedToKill = totalStakedToKill.add(_amount);

		_updateFundStateAfterStake();
	}

	function unstakeToPause(uint256 _amount) external {
		_checkCloseTime();
		require(currentState != FundStates.setup, "TREASURYV1: FundStates.setup");
		require(stakedToPause[msg.sender] >= _amount, "TREASURYV1: insufficent balance to unstakeToPause");

		_transfer(address(this), msg.sender, _amount);

		stakedToPause[msg.sender] = stakedToPause[msg.sender].sub(_amount);
		totalStakedToPause = totalStakedToPause.sub(_amount);

		_updateFundStateAfterStake();
	}

	function unstakeToKill(uint256 _amount) external {
		_checkCloseTime();
		require(currentState != FundStates.setup, "TREASURYV1: FundStates.setup");
		require(stakedToKill[msg.sender] >= _amount, "TREASURYV1: insufficent balance to unstakeToKill");

		_transfer(address(this), msg.sender, _amount);

		stakedToKill[msg.sender] = stakedToKill[msg.sender].sub(_amount);
		totalStakedToKill = totalStakedToKill.sub(_amount);

		_updateFundStateAfterStake();
	}

	function _updateFundStateAfterStake() internal {
		// closes are final, cannot unclose
		if (currentState == FundStates.closed){
			return;
		}
		// check if the fund will irreversibly close
		if (totalStakedToKill > totalSupply().div(max).mul(killQuorum)){
			_changeFundState(FundStates.closed);
			return;
		}
		// check if the fund will pause/unpause
		uint256 _pausedStake = totalStakedToPause.add(totalStakedToKill);
		if (_pausedStake > totalSupply().div(max).mul(pauseQuorum) && currentState == FundStates.active){
			_changeFundState(FundStates.paused);
			return;
		}
		if (_pausedStake <= totalSupply().div(max).mul(pauseQuorum) && currentState == FundStates.paused){
			_changeFundState(FundStates.active);
			return;
		}
	}

	function _changeFundState(FundStates _state) internal {
		// cannot be changed AWAY FROM closed or TO setup
		if (currentState == FundStates.closed || _state == FundStates.setup){
			return;
		}
		currentState = _state;
	}


	// fund is over, claim your proportional proceeds with SVC001 tokens. if fund is not closed but time's up, this will also close the fund
	function claim(address[] calldata _tokens, uint256[] calldata _amounts) external {
		_checkCloseTime();
		require(currentState == FundStates.closed, "TREASURYV1: !FundStates.closed");
		require(_tokens.length == _amounts.length, "TREASURYV1: length mismatch");
		require(_tokens.length <= 50, "TREASURYV1: length > 50"); // don't allow unbounded loops, bad design, gas issues

		// we should be able to send about 50 ETH tokens at a maximum in a loop
		// if we have more tokens than this in the fund, we can find a solution...
			// one would be wrapping all "valueless" tokens in another token (via sell / buy flow)
			// users can claim this bundled token, and if a "valueless" token ever has value, then they can do a similar cash out to the valueless token
			// there is a very low chance that there's >50 tokens that users want to claim. Probably more like 5-10 (given a normal VC story of many fails, some big successes)
		// we could alternatively make a different claim flow that doesn't use loops, but the gas and hassle of making 50 txs to claim 50 tokens is way worse

		uint256 _balance = balanceOf(msg.sender);
		uint256 _proportionE18 = _balance.mul(1e18).div(totalSupply());

		_burn(msg.sender, _balance);

		// automatically send a user their ETH balance, everyone wants ETH, the goal of the fund is to make ETH.
		uint256 _proportionToken = address(this).balance.mul(_proportionE18).div(1e18);
		msg.sender.transfer(_proportionToken);

		for (uint256 i = 0; i < _tokens.length; i++){
			require(_tokens[i] != address(this), "can't claim _this");
			require(boughtTokens[_tokens[i]], "!boughtToken");

			_proportionToken = IERC20(_tokens[i]).balanceOf(address(this)).mul(_proportionE18).div(1e18);
			IERC20(_tokens[i]).safeTransfer(msg.sender, _proportionToken);
		}
	}

	// maintenance function: check if the fund is out of time, if so, close it. rebalance the current investment cap based on a rolling average.
	function _checkCloseTime() internal {
		if (block.timestamp > fundCloseTime && currentState != FundStates.setup){
			_changeFundState(FundStates.closed);
		}
	}

	// updates currentInvestmentUtilization based on a 30 day rolling average. If there are 30 days since the last investment, the utilization is zero. otherwise, deprec. it at a constant rate.
	function _updateInvestmentUtilization(uint256 _newInvestment) internal {
		uint256 proposedUtilization = getUtilization(_newInvestment);
		require(proposedUtilization <= maxInvestment, "TREASURYV1: utilization > maxInvestment");

		currentInvestmentUtilization = proposedUtilization;
		lastInvestTime = block.timestamp;
	}

	// get the total utilization from a possible _newInvestment
	function getUtilization(uint256 _newInvestment) public view returns (uint256){
		uint256 _lastInvestTimeDiff = block.timestamp.sub(lastInvestTime);
		if (_lastInvestTimeDiff >= THIRTY_DAYS){
			return _newInvestment;
		}
		else {
			// current * ((thirty_days - time elapsed) / thirty_days)
			uint256 _depreciateUtilization = currentInvestmentUtilization.div(THIRTY_DAYS).mul(THIRTY_DAYS.sub(_lastInvestTimeDiff));
			return _newInvestment.add(_depreciateUtilization);
		}
	}

	// get the maximum amount possible to invest at this time
	function availableToInvest() external view returns (uint256){
		return maxInvestment.sub(getUtilization(0));
	}

	// only called in emergencies. if the contract is bricked or for some reason cannot function, we escape all assets and will return to their owners manually.
	// v1 of the Treasury is not completely trustless because of this mechanism, we prioritize fund safety & retreivability of the assets instead
	function emergencyEscape(address _tokenContract, address payable _to, uint256 _amount) external {
		require(msg.sender == advisoryMultisig, "TREASURYV1: !advisoryMultisig");

		if (_tokenContract != address(0)){
			IERC20(_tokenContract).safeTransfer(_to, _amount);
		}
		else {
			_to.transfer(_amount);
		}
	}
}