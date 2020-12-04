# Treasury, STACK Token & Distribution Contracts

### Testing these contracts:
To test these contracts, you can run unit or integration tests (yEarn integration). Rename the correct `migrations_XXX` folders to `migrations` and then run `truffle migrate`. They will need different ganache-cli instances, detailed more in their separate READMEs.

TODO: work on `truffle test` implementation over `truffle migrate`. This is the proper way to run tests, but had some compatibility issues earlier.

### VCTreasuryV1 (./Treasury/VCTreasuryV1.sol)

This contract is the "product" of the first iteration of stacker.vc. This smart contract creates full functionality for a trust-minimized, decentralized VC investment fund. 


### STACK Token (./Token/STACKToken.sol)

This contract inherits from the OpenZeppelin standard token contracts, as found here: https://docs.openzeppelin.com/contracts/2.x/api/token/erc20

We add burn functionality (ERC20Burnable from OpenZeppelin), and a way to allow different addresses/contracts to mint tokens. This minting functionality will be used in our Gauge contracts in order to distribute STACK tokens.

### Gauge Distribution 1 (./Token/GaugeD1.sol)

This is a gauge contract using this algorithm for a per-block token distribution: https://uploads-ssl.webflow.com/5ad71ffeb79acc67c8bcdaba/5ad8d1193a40977462982470_scalable-reward-distribution-paper.pdf

Users are rewarded by committing their funds to the VC Fund (either a soft- or hard-commit). Users will receive a bonus for hard-committing to the fund. A hard-commit is a irrevocable committment to Stacker.vc Fund #1. A soft-commit is a withdrawable committment to Stacker.vc Fund #1. A soft-committment can be withdrawn in a 3 month window, but after this, the fund closes and it will be committed to the VC Fund as well.

The more tokens you commit to the fund, and the more you hard-commit these tokens, the more STACK tokens you will receive. This STACK token distribution will take place for a 3-month window (same 3 month window that the fund has to close).

All tokens committed to the fund will receive _SVC01 Tokens_ after the fund closes, in proportion to how much ETH (equivalent) that the user committed to the fund. This will be done via a publicly available and auditable snapshot on the fund-close date.

##### governance
This address has some control over the distribution. It can change the endBlock (if the end block has not passed yet), add new bridges to the fund (yEarn integration), change the emission rate, close the fund (once it reaches the hard cap... soft-commits can still withdraw), and change the vcHolding account. This address can also sweep soft-commits to the vcHolding address, ONLY when the fund has closed.

##### vcHolding
This address holds the funds that have been committed to the Stacker.vc Fund #1. This address will be set to a multisig wallet with public participants for safe-guarding.

##### acceptToken
This is the token that the Gauge accepts for committment to the fund. Users can deposit this token and receive their STACK bonus.

##### vaultGaugeBridge
Another smart contract to allow users to deposit into yEarn and then into the Gauge in a single transaction. Bridge contract is set once in the constructor.

##### emissionRate
This is how many STACK tokens (18 decimals) get emitted per block.

##### depositedCommitSoft
Number of _acceptToken_ that has been soft-committed to the fund.

##### depositedCommitHard
Number of _acceptToken_ that has been hard-committed to the fund.

##### commitSoftWeight & commitHardWeight
The amount of STACK bonus a user gets for soft/hard-committing. 1x and 4x, respectively.

##### mapping(address => CommitState) public balances;
A mapping to track user committments per level, and _tokensAccrued_ for STACK distribution.

##### fundOpen
Governance can close the fund, and reject new commits and upgrades. Soft-commits can always be withdrawn until the deadline.

##### startBlock & endBlock
The times that the STACK token distribution opens and closes. lastBlock can be adjusted, but startBlock is fixed.

##### tokensAccrued
The amount of STACK tokens accrued per _acceptToken_ committed to the fund. See above Gauge algorithm for more info.

##### setGovernance() & setVCHolding() & setEmissionRate() & setFundOpen() & setEndBlock()
Permissioned action for _governance_ to change constants.

##### deposit()
Allows users to deposit funds into soft-commit for hard-commit buckets & start accruing STACK tokens. Also claims STACK tokens for a user.

##### upgradeCommit()
Allows a user to upgrade from softCommit to hardCommit level. Also claims STACK tokens for a user.

##### withdraw()
Allows a user to withdraw a soft-commit before deadline. Also claims STACK tokens for a user.

##### claimSTACK()
Claims STACK tokens for a user.

##### claimSTACK() internal
Claims a users STACK tokens and sends to them, if their _tokensAccrued_ is less than the global _tokensAccrued_. Updates their _tokensAccrued_ variable and sets it equal to the global variable after claiming.

##### kick() internal
Asks STACK token contract to mint more tokens. This would be the difference of blocks since the last time this was called, times the emission rate per block.

##### sweepCommitSoft()
Allows the governance address to sweep all soft-committed funds to the _vcHolding_ account. This can ONLY be called after the deadline is complete, and can only be called once. This marks the start of the fund!

##### getTotalWeight()
Total _acceptToken_ multiplied by the weight of the STACK bonus for the deposit type.

##### getTotalBalance()
Total _acceptToken_ deposited into the contract.

##### getUserWeight()
Gets weight of a user (_acceptToken_ deposited times STACK distribution bonus).

##### getUserBalance()
Total _acceptToken_ deposited by a users into the contract.

### yEarn Vault Gauge Bridge (./Token/VaultGaugeBridge.sol)
This contract allows users to deposit their ERC20/ETH into yEarn to receive interest, and then deposit those yTokens into a gauge to commit to the Stacker.vc Fund #1. This bridge contract allows a user to do this in a single action (usually would take two). The user can also withdraw in a similar way, from Gauge -> yEarn -> ERC20 base tokens (if they don't want to withdraw the yToken from a Gauge, but instead withdraw the underlying).

Users can deposit yTokens directly to the Gauge contract, and bypass this Bridge contract. They can also withdraw yTokens directly from a Gauge, and bypass this contract on a withdraw. It's simply to make the UI better, less fees & waiting!

##### WETH_VAULT
Address of the yEarn WETH vault. This vault is slightly different to support ETH correctly.

##### governance
This user can set up new bridges for additional yEarn coins that are to be accepted.

##### receive() (fallback function)
On receipt of ETH, act as if the depositor is hard-committing to the Stacker.vc fund. Unless this is the yEarn vault, in which case this is just normal behavior of the contract, so don't do anything.

##### setGovernance()
Permissioned action to change the governance account.

##### newBridge()
Permissioned action to add a new deposit bridge from yEarn -> STACK Gauge.

##### depositBridge()
Deposits an _amount_ of token into yEarn _vault_ of behalf of the calling user. Then deposits the received yTokens into _commit_ (true = hard-commit, false = soft-commit).

##### depositBridgeETH()
Similar to the above function, but takes an initial send of ETH, deposits into yEarn, and then deposits yETH into the Gauge.

##### withdrawBridge()
Withdraws a soft-commit from the Gauge, and then withdraws the underlying token from yEarn. Then sends this underlying token back to the user.

##### withdrawBridgeETH()
Similar to the above function, but withdraws from the yETH Gauge contract and receives ETH from the yEarn yETH vault. 

##### withdrawGauge() internal
A helper function to withdraw from a gauge contract.

##### depositGauge() internal
A helper function to deposit into a gauge contract.

### STACK Liquidity Provider Gauge (./Token/LPGauge.sol)
This a simplied Gauge contract from the above Gauge contract. This doesn't have anything to do with the VC Fund #1 committment scheme, but allows users to be given a bonus for providing liquidity to the STACK token on Uniswap and Balancer markets. Sufficient liquidity for trading is very important for a fledgling project, and we seek to incentivize providing liquidity via this contract. 

Users that provide liquidity to Uniswap STACK<>USDT, Uniswap STACK<>ETH, and Balancer STACK 80% <> ETH 20% will be rewarded by these contracts. Users must deposit their LP Tokens in this contract to be rewarded.
