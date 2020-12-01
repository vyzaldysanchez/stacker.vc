// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

interface IMinter {
	function minters(address) external returns (bool);
	function mint(address, uint256) external;
}