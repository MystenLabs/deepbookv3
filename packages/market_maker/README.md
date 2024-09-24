# Scripts for calling DeepBook V3

To install dependencies

```bash
pnpm install
```

To run main.ts

```bash
pnpm start
```

## Deposit funds

You need the following in your .env file:
PRIVATE_KEY = "suiprivkey..."
BALANCE_MANAGER = "0xabc"

If you haven't created a balance manager, then uncomment the `await mm.createAndShareBM();` line and run it. Go to the explorer, copy the newly created shared object address, and set it in your .env file.

`await mm.depositCoins();` will deposit four of the whitelisted coins from your wallet into your balance manager. All numbers are scaled within the SDK.
