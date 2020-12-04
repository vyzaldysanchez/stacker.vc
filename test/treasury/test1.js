const VCTreasuryV1 = artifacts.require("VCTreasuryV1");
const BN = require('bn.js');

const ONE_YEAR = 31536000;

contract("test treasury setup", async (accounts) => {

	async function _init(){
		return await VCTreasuryV1.new(accounts[5], accounts[6], {from: accounts[0]})
	}

	it("should init contract", async () => {
		let instance = await _init();

		assert.equal(await instance.deployer(), accounts[0]);
		assert.equal(await instance.councilMultisig(), accounts[5]);
		assert.equal(await instance.treasury(), accounts[6]);

		assert.equal((await instance.currentState()).toString(), "0");
	});

	it("should setCouncilMultisig", async () => {
		let instance = await _init();

		await instance.setCouncilMultisig(accounts[7], {from: accounts[5]});

		assert.equal(await instance.councilMultisig(), accounts[7]);
	});

	it("should setDeployer", async () => {
		let instance = await _init();

		await instance.setDeployer(accounts[7], {from: accounts[0]});
		assert.equal(await instance.deployer(), accounts[7]);

		await instance.setDeployer(accounts[8], {from: accounts[5]});
		assert.equal(await instance.deployer(), accounts[8]);
	});

	it("should setTreasury", async () => {
		let instance = await _init();

		await instance.setTreasury(accounts[7], {from: accounts[5]});
		assert.equal(await instance.treasury(), accounts[7]);

		await instance.setTreasury(accounts[8], {from: accounts[7]});
		assert.equal(await instance.treasury(), accounts[8]);
	});

	it("should setBoughtToken", async () => {
		let instance = await _init();

		await instance.setBoughtToken(accounts[9], {from: accounts[5]});
		assert(await instance.getBoughtToken(accounts[9]));
	});

	it("should issueTokens 100x", async () => {
		let instance = await _init();

		let accts1 = [];
		let amts1 = [];
		for (let i = 100; i < 150; i++){
			accts1.push(accounts[i]);
			amts1.push(web3.utils.toWei("1", "ether"));
		}

		let accts2 = [];
		let amts2 = [];
		for (let i = 150; i < 200; i++){
			accts2.push(accounts[i]);
			amts2.push(web3.utils.toWei("2", "ether"));
		}

		await instance.issueTokens(accts1, amts1, {from: accounts[0]});
		await instance.issueTokens(accts2, amts2, {from: accounts[0]});

		assert.equal((await instance.totalSupply()).toString(), web3.utils.toWei("150", "ether"));
		assert.equal((await instance.balanceOf(accounts[111])).toString(), web3.utils.toWei("1", "ether"));
		assert.equal((await instance.balanceOf(accounts[166])).toString(), web3.utils.toWei("2", "ether"));
	});

	async function _issueTokens(instance){
		instance.issueTokens([accounts[100], accounts[101], accounts[102]], [web3.utils.toWei("2", "ether"), web3.utils.toWei("2", "ether"), web3.utils.toWei("1", "ether")]);
	}

	async function _startFund(instance){
		instance.startFund({value: web3.utils.toWei("50", "ether"), from: accounts[5]});
	}

	it("should issueTokens & startFund", async () => {
		let instance = await _init();
		await _issueTokens(instance);

		assert.equal((await instance.totalSupply()).toString(), web3.utils.toWei("5", "ether"));
		assert.equal((await instance.balanceOf(accounts[100])).toString(), web3.utils.toWei("2", "ether"));
		assert.equal((await instance.balanceOf(accounts[101])).toString(), web3.utils.toWei("2", "ether"));
		assert.equal((await instance.balanceOf(accounts[102])).toString(), web3.utils.toWei("1", "ether"));

		// init fund with 3 token holders, 5 SVC001 tokens total
		// 50 ETH to start the fund
		await _startFund(instance);

		console.log("fund start time:", (await instance.fundStartTime()).toString());
		console.log("fund end time:", (await instance.fundCloseTime()).toString());

		assert.equal((await instance.initETH()).toString(), web3.utils.toWei("50", "ether"));
		assert.equal((await instance.maxInvestment()).toString(), web3.utils.toWei("10", "ether"));
		assert.equal((await instance.currentState()).toString(), "1");
		assert.equal((await instance.availableToInvest()).toString(), web3.utils.toWei("10", "ether"));
	});

	it("should stakeToPause & paused & unstakeToPause & active", async () => {
		let instance = await _init();
		await _issueTokens(instance);
		await _startFund(instance);

		// if user 100 stakes to pause, that's 2/5 = 40% > pause quorum
		await instance.stakeToPause(web3.utils.toWei("2", "ether"), {from: accounts[100]});
		assert.equal((await instance.currentState()).toString(), "2"); // paused state
		assert.equal((await instance.getStakedToPause(accounts[100])).toString(), web3.utils.toWei("2", "ether"));
		assert.equal((await instance.totalStakedToPause()).toString(), web3.utils.toWei("2", "ether"));

		await instance.unstakeToPause(web3.utils.toWei("2", "ether"), {from: accounts[100]});
		assert.equal((await instance.currentState()).toString(), "1");
		assert.equal((await instance.getStakedToPause(accounts[100])).toString(), "0");
		assert.equal((await instance.totalStakedToPause()).toString(), "0");
	});

	it("should stakeToKill & closed & killed & unstakeToKill", async () => {
		let instance = await _init();
		await _issueTokens(instance);
		await _startFund(instance);

		await instance.stakeToKill(web3.utils.toWei("2", "ether"), {from: accounts[100]});
		assert.equal((await instance.currentState()).toString(), "2"); // paused state
		assert.equal((await instance.getStakedToKill(accounts[100])).toString(), web3.utils.toWei("2", "ether"));
		assert.equal((await instance.totalStakedToKill()).toString(), web3.utils.toWei("2", "ether"));

		await instance.stakeToKill(web3.utils.toWei("1", "ether"), {from: accounts[102]});
		assert.equal((await instance.currentState()).toString(), "3"); // closed state
		assert(await instance.killed()); // killed maliciously
		assert.equal((await instance.getStakedToKill(accounts[102])).toString(), web3.utils.toWei("1", "ether"));
		assert.equal((await instance.totalStakedToKill()).toString(), web3.utils.toWei("3", "ether"));

		await instance.unstakeToKill(web3.utils.toWei("1", "ether"), {from: accounts[100]});
		assert.equal((await instance.currentState()).toString(), "3"); // closed state
		assert(await instance.killed()); // killed maliciously
		assert.equal((await instance.getStakedToKill(accounts[100])).toString(), web3.utils.toWei("1", "ether"));
		assert.equal((await instance.totalStakedToKill()).toString(), web3.utils.toWei("2", "ether"));

		await instance.unstakeToKill(web3.utils.toWei("1", "ether"), {from: accounts[102]});
		assert.equal((await instance.currentState()).toString(), "3"); // closed state
		assert(await instance.killed()); // killed maliciously
		assert.equal((await instance.getStakedToKill(accounts[102])).toString(), "0");
		assert.equal((await instance.totalStakedToKill()).toString(), web3.utils.toWei("1", "ether"));

		await instance.unstakeToKill(web3.utils.toWei("1", "ether"), {from: accounts[100]});
		assert.equal((await instance.currentState()).toString(), "3"); // closed state
		assert(await instance.killed()); // killed maliciously
		assert.equal((await instance.getStakedToKill(accounts[100])).toString(), "0");
		assert.equal((await instance.totalStakedToKill()).toString(), "0");
	});

	it("should stakeToPause & stakeToKill & paused", async () => {
		let instance = await _init();
		await _issueTokens(instance);
		await _startFund(instance);

		await instance.stakeToKill(web3.utils.toWei("1", "ether"), {from: accounts[100]});
		await instance.stakeToPause(web3.utils.toWei("1", "ether"), {from: accounts[100]});
		assert.equal((await instance.currentState()).toString(), "2"); // paused state
		assert.equal((await instance.getStakedToKill(accounts[100])).toString(), web3.utils.toWei("1", "ether"));
		assert.equal((await instance.getStakedToPause(accounts[100])).toString(), web3.utils.toWei("1", "ether"));
		assert.equal((await instance.totalStakedToKill()).toString(), web3.utils.toWei("1", "ether"));
		assert.equal((await instance.totalStakedToPause()).toString(), web3.utils.toWei("1", "ether"));
	});

	async function _increasetime(_time){
		await web3.currentProvider.send({jsonrpc: '2.0', method: 'evm_increaseTime', params: [_time], id: new Date().getTime()}, (error, response) => {if (error){console.log(error)}});
		await web3.currentProvider.send({jsonrpc: '2.0', method: 'evm_mine', id: new Date().getTime()}, (error, response) => {if (error){console.log(error)}});
	}

	it("should fast-forward 1 year and close fund, redeem ETH for SVC001 tokens", async () => {
		let instance = await _init();
		await _issueTokens(instance);
		await _startFund(instance);

		console.log("now:", (await web3.eth.getBlock("latest")).timestamp.toString());
		console.log("fund end time:", (await instance.fundCloseTime()).toString());

		// increase time by 1 year
		await _increasetime(ONE_YEAR);

		console.log("now:", (await web3.eth.getBlock("latest")).timestamp.toString());

		assert.equal((await instance.currentState()).toString(), "1"); // open state
		await instance.checkCloseTime({from: accounts[2]});
		assert.equal((await instance.currentState()).toString(), "3"); // closed state

		// since the fund was closed non-maliciously, there is a 5% fee
		// this means that 5*1.05 = 5.25 SVC001 tokens exist
		assert.equal((await instance.balanceOf(accounts[5])).toString(), web3.utils.toWei("0.125", "ether"));
		assert.equal((await instance.balanceOf(accounts[6])).toString(), web3.utils.toWei("0.125", "ether"));
		assert.equal((await instance.totalSupply()).toString(), web3.utils.toWei("5.25", "ether"));

		assert.equal((await web3.eth.getBalance(instance.address)).toString(), web3.utils.toWei("50", "ether"));
		await instance.claim([], {from: accounts[100]});
		// the user was sent 50e18 * (2/5.25) eth, so >>> python int(50e18-(50e18*2/5.25)) = 30952380952380952576 remaining
		console.log((await web3.eth.getBalance(instance.address)).toString(), "vs.", "30952380952380952576", "<-- difference from rounding, 176 wei");
		assert.equal((await web3.eth.getBalance(instance.address)).toString(), "30952380952380952400");

		assert.equal((await instance.balanceOf(accounts[100])).toString(), "0");
		assert.equal((await instance.totalSupply()).toString(), web3.utils.toWei("3.25", "ether"));
	});






});