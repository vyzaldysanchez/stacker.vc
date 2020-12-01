// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

interface IGaugeD1 {	
	function deposit(uint256 _amountCommitSoft, uint256 _amountCommitHard, address _creditTo) external;
	function withdraw(uint256 _amount, address _withdrawFor) external;
}
