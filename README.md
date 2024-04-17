# DeepBook V3
DeepBook V3 introduces the DEEP token, new features around governance, improved account abstraction, and enhancements to the existing matching engine. This design comprises of two shared objects: State & Pool, and one owned object: Account. 

The State shared object registers new pools, manages DEEP price sources, conducts governance, and tracks stakes. The Pool manages individual users and order execution. The Account is where all of user's funds are stored.
# Key Design Decisions
It's important to keep two key design decisions in mind as you read this document. 
### State vs Pool level data
State and Pool serve distinct roles in data management. State aggregates total amounts, such as overall staked values for each pool, while Pool stores individual amounts, like stakes from each user within a pool.

Pool shared objects do not need aggregate totals, as this information is efficiently maintained at the State level. Conversely, State avoids redundant data storage by leveraging Pool-level granularity. This design minimizes complexity, avoiding the need for nested data structures.

The combination of State and Pool is used to conduct governance.
### Epoch Refresh / Data Processing on Demand
Epoch transitions play a pivotal role in DeepBook's functionality. For instance, rewards for staked DEEP tokens start accumulating only in the subsequent epoch. To facilitate timely updates without relying on periodic cron jobs, data is refreshed on-demand triggered by relevant user actions. These refreshes are light, simply updating less than 5 variables from their `current_` to `next_` amounts.

At the State level, epoch refresh is triggered by the first stake, unstake, or proposal submission. This updates total voting power for this epoch and clears old proposals.

At the Pool level, epoch refresh is prompted by the first order placement. This updates the current fee tier.

At the user level, epoch refresh occurs upon the first order placement or reward claim. This updates the individual users trading data.
# Components
## State
State tracks all metadata per pool. It ensures only a single pool exists for any given pair of assets. If SUI/USDC exists, you cannot create USDC/SUI. Pool (capital P) will refer to the Pool shared object, while pool will refer to the pool metadata stored inside of State.

Each pool conducts governance independently from each other. The first stake, unstake, or proposal submission against an individual pool will refresh the metadata of that pool. This will update the voting power, quorum for the epoch, and reset governance in that pool. At any point during an epoch, if the total votes on a proposal reaches the quorum, then proposal parameters are pushed onto that Pool and set as next_pool_state. 

![image info](DeepBook%20Governance%20Timeline.png)

Staking DEEP will merge the user's DEEP tokens into the vault and push the user's next_stake_amount onto Pool. 
## Pool
### Refresh
### Orders
### DEEP fees
### Deposit & Withdrawals from Account, Settled Funds
### User Rebates and Burns, Stake
## Account
[IMG]
## Feedback from MMs