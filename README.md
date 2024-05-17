# DeepBook V3
DeepBook V3 introduces the DEEP token, new features around governance, improved account abstraction, and enhancements to the existing matching engine. DBv3 is comprised of the primary Pool shared object, an Account shared object for balance management, and a Registry shared object for registering pools.

Pool is made up of three distinct parts: Book, State and Vault. These parts define the flow for the different types of actions that can be performed on DeepBook. 
## Pool
### Categorizing Parts
To define DBv3's flow, we will first categorize the unique parts of the Pool into three buckets: Book, State and Vault.
 1. Book - manages reading and writing to the order book. It fills orders and places orders into the order book.
 2. State - the most complex: maintains individual user data, overall volumes, historic volumes, and governance.
 3. Vault - the least complex: settles users funds after action execution. 
### Categorizing Actions
Let's also categorize all actions into four buckets: order, stake, governance, and operational.
 1. Order actions include placing, canceling, or modifying orders. These actions are processed in Book, State, then Vault in that order.
 2. Stake actions include staking or unstaking DEEP tokens as well as burning/redeeming DEEP rewards. These actions are processed in State then Vault in that order.
 3. Governance actions include creating new proposals and voting for existing proposals. These actions are processed in State.
 4. Operational includes the single action to feed a DEEP data point into the pool. This action is processed in Vault.

Each part builds on top of the previous one. By maintaining this Book then State then Vault relationship, we are able to provide data availability guarantees, improve code readability, and ease of maintenance and upgrade of the protocol. Next, we will go over placing an order, staking, and voting step by step to visualize DBv3's flow.
### Place Limit Order
When placing a limit order, an `OrderInfo` object is created and its execution is as simple as:
```
self.book.create_order(&mut order_info, ...);
self.state.process_create(&order_info, ...);
self.vault.settle_order(&order_info, ...);
self.vault.settle_account(...);
```
Notice the three parts and the maintenance of their relationship. The `Book` takes the `order_info` object and executes any overlapping amounts and adds the remaining amount into the order book, mutating the object as it does so. This gives `State` enough information to update every user affected as well as increase the overall volumes. Finally, `Vault` sets any settled amounts for all affected users by settling the order, then settles the account by moving the actual balances between the account and the pool.

`self.book.create_order()`
This takes us to the `book` module. It maintains two BigVectors that hold `Order`s.
>**Order** is a compact object that contains the minimum amount of data needed for matching. If an OrderInfo object has unfilled quantity after matching, then it will be converted into an Order via `order_info.to_order()` and injected into the book.

Our order_info object traverses into the `match_against_book()` function. Here lies the core component of the matching engine: we iterate over each `Order` within the appropriate side of the book, calling OrderInfo's `match_maker()`. All trades, regardless of the direction, type, or origin, will use this single function to match orders. This function mutates both the OrderInfo that we started with as well as the Order that lies within the book, producing `Fill`s. These are appended into the fills vector within OrderInfo and are used to update the State. Any remaining quantity is injected into the book, and the OrderInfo object is returned to the caller.

`self.state.process_create()`
In the `state` module, each action is processed with an appropriate `process_action()` function. In the case of create, the resulting fills are iterated, updating the affected account's open orders and settled balances. The overall volume is updated in `history` and the order is added to the taker's open orders.
>When an account places an order, it is executed against resting orders that have been placed by makers in the past. Settled balances are funds that are stored for the maker of the order to be claimed later. This is done by the Vault, which settles all funds for the user after every action.


`self.vault.settle_order()`
For order creation only, the vault first settles the order to calculate the different balances that are moved for the account. By this point, the order can be completely unfilled, partially filled, or completely filled. For any filled amount, the vault calculates the fees owed by the account using the taker_fee rate. For the remaining unfilled amount, it calculates the fees owed using the maker_fee rate. Fees, combined with the actual quantity of the order, is updated for the account's settled/owed balances.

`self.vault.settle_account()`
In this final step, the Vault checks all of the settled and owed balances for a given account, and moves the appropriate balances between the account and the pool.

Placing a limit order is the most complex action a user can take on DeepBook. There are different types of orders, different fee rates, and different matching results. But with DeepBook's three part flow, its easy to visualize and break down this complex task into smaller pieces and work them out independently. By isolating the core components such as matching orders and settling funds, we minimize the surface area for bugs. Further, the addition of any new actions is simplified with the intuitive nature of the Book then State then Vault relationship.
### Stake

### Vote

## Other Important Details
### DEEP Price
### Fees with DEEP
### Epoch Transition