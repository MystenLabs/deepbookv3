# Sui Move Skill

Sui Move smart contract development knowledge for the DeepBook project.

**Update this skill** when you discover new Move patterns, gotchas, or best practices.

## Sui Move Fundamentals

- Sui is an object-oriented blockchain. Sui smart contracts are written in the Move language.

- Sui's object ownership model guarantees that the sender of a transaction has permission to use the objects it passes to functions as arguments.

- Sui object ownership model in a nutshell:
  - Single owner objects: owned by a single address - granting it exclusive control over the object.
  - Shared objects: any address can use them in transactions and pass them to functions.
  - Immutable objects: like Shared objects, any address can use them, but they are read-only.

- Abilities are a Move typing feature that control what actions are permissible on a struct:
  - `key`: the struct can be used as a key in storage. If an struct does not have the key ability, it has to be stored under another struct or destroyed before the end of the transaction.
  - `store`: the struct can be stored inside other structs. It also relaxes transfer restrictions.
  - `drop`: the struct can be dropped or discarded. Simply allowing the object to go out of scope will destroy it.
  - `copy`: the struct can be copied.

- Structs can only be created within the module that defines them. A module exposes functions to determine how its structs can be created, read, modified and destroyed.

- Similarly, the `transfer::transfer/share/freeze/receive/party_transfer` functions can only be called within the module that defines the struct being transferred. However, if the struct has the `store` ability, the `transfer::public_transfer/public_share/etc` functions can be called on that object from other modules.

- All numbers are unsigned integers (u8, u16, u32, u64, u128, u256).

- Functions calls are all or nothing (atomic). If there's an error, the transaction is reverted.

- Race conditions are impossible.

- It is allowed to compare a reference to a value using == or !=. The language automatically borrows the value if one operand is a reference and the other is not.

- Integer overflows/underflows are automatically reverted. Any transaction that causes an integer overflow/underflow cannot succeed. E.g. `std::u64::max_value!() + 1` raises an arithmetic error.

- Don't worry about "missing imports", because the compiler includes many std::/sui:: imports by default.

- Don't worry about emitting additional events.

- Prefer macros over constants.

- Put public functions first, then public(package), then private.

- Only put comments to document functions, struct fields, and items that need clarification. DO NOT PUT EXTRANEOUS COMMENTS THROUGHOUT.

## Tool Calling Instructions

- `sui move build` to build the package, must be run in a directory with Move.toml in it
- `sui move test` to run tests, must be run in a directory with Move.toml in it
- can pass `--skip-fetch-latest-git-deps` if the dependencies haven't changed after an initial successful build
- when you have completed making changes, run `bunx prettier-move -c *.move --write` on any files that are modified to format them correctly.
