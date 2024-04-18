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
### Orders
To place a maker order within the trading system, several key parameters are required: the pool object, user account, client_order_id, price, quantity (always in terms of the base asset), and whether the order is a bid (buy) or ask (sell). The system first attempts to cover the trade amount using any settled balances the user has within the pool. If these are insufficient, it will draw the required funds from the user's account.

An order remains active in the system either until it is fully settled through trades or the user decides to cancel it. Cancelling an order triggers a mechanism that refunds the remaining order funds and fees back into the user's account. This efficient handling ensures that users can share their assets across multiple pools.

### DEEP Price
The DEEP price is crucial for calculating transaction fees within the trading pool, and it is dynamically updated in the DeepPrice struct to reflect the prevailing market conditions. This price is revised at regular intervals within the pool's configuration system. The initial methodology for determining the DEEP price involves calculating a moving average of the price points recorded over the past hour. This approach helps in moderating the impact of short-term market fluctuations on fee calculations, ensuring that fees are based on a more stable and representative market price. This mechanism enables the pool to adapt its fee structure dynamically, aligning it closely with real-time economic conditions and maintaining fairness in trading charges.

### Trading fees
Fees within the trading pool are structured differently based on the verification status of the pool. In verified pools, the deep_config includes a DeepPrice object. The fees are computed in terms of DEEP tokens, using rates specified as "deep_per_base" or "deep_per_quote" within DeepPrice. Collected fees are directly deposited into the pool balances.

Conversely, in unverified pools where deep_config does not have a DeepPrice object, fees for ask orders are calculated in terms of the base asset, while fees for bid orders are calculated in terms of the quote asset. This means that the transaction fees comes directly from the primary assets involved in trading. Collected fees are immediately sent to treasury at trade settlement.

### Deposits and Withdrawals on Pool Level, Settled Funds
Automated Deposits: The system automates deposits to ensure users can always engage in trading activities, even if preliminary checks reveal insufficient funds in their settled balances within the pool. This automation enhances user experience by removing manual steps and potential trading delays.

No Manual Deposit: Users cannot manually deposit assets into the pool custodian; instead, this process is managed automatically by the system based on trading needs and balance requirements. This design choice is aimed at simplifying interactions and preventing errors or misuse.

Security and Permission Checks: Implicit in this process are security and permission checks. Withdrawals from user accounts require authorization to ensure that only the account owner or authorized parties can initiate such transfers.

Funds from Settled Orders: Once user orders are settled, the funds are stored in the User struct at the pool level. Users can then use these funds to place new orders or withdraw them at any time.

### User Rebates and Burns/Treasury
Rebates serve as incentives for users, especially market makers, who contribute liquidity to the trading pool. These rebates represent a portion of the transaction fees generated from trading activities and are designed to encourage ongoing participation and liquidity enhancement in the pool. Rebates are accrued over each epoch, reflecting the user's level of activity during that period, and users can claim them when they choose to. Important to note that rebates are only available for pools that are verified and where trading fees are paid in DEEP.

Upon claiming rebates, the specified amount is transferred back to the user from the pool's balance of DEEP tokens. Concurrently, any portion of the fees that is not rebated is burned.

## Account
Users can create new accounts and are able to deposit or withdraw any coin types. Deposits involve adding coins to an account's balance, which is stored dynamically and can be merged with existing balances of the same type. Withdrawals check if sufficient funds are available and then allow users to remove a specified amount from their balance. 

The account structure also maintains a reference to the owner's address, and the system includes functions to retrieve the owner of an account. This framework is built to handle transactions securely within a flexible structure, ensuring that operations like deposits and withdrawals are efficiently managed according to the account's stored values and types of coins.

Users can pass the account object for placing orders within any deepbook pool, provided the account holds enough assets. This enables the utilization of shared balances across various pools containing the same assets, allowing for transactions in pools such as SUI/USDC and SUI/USDT using a single SUI balance.

## Feedback from MMs
- Important to have the ability to create multiple accounts for added flexibility and as a precaution in case an account becomes locked.
- We will support the creation of child accounts / premissions in Account.

- Limit the number of calls to fetch Level 2 order book data (from 3 calls to 1 call) to avoid excessive load. They have to first make a call to know what the midprice is, then make two calls for bid book and ask book with the given price.
- We solve this by modifying v2's order book retrieval. You will be able to retrieve the order book in two ways: specify a lower, upper price limits or specify the number of ticks. The first option exists in V2, the second will automatically fetch the first n bid and ask ticks.

- Capability to retrieve historical trades by account. This is required for trade reconciliation, auditing.
- We can solve this with an off-chain solution to manage the data efficiently and maintain performance without overburdening the on-chain systems.

- A readonly endpoint get_amount_out: given some amount as input, get the amount out if it were executed as a market order.

- Better documentation