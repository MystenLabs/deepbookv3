import { Transaction } from "@mysten/sui/transactions";
import { namedPackagesPlugin } from "@mysten/sui/transactions";
import { SuiGraphQLClient } from "@mysten/sui/graphql";

Transaction.registerGlobalSerializationPlugin(
  "namedPackagesPlugin",
  namedPackagesPlugin({
    suiGraphQLClient: new SuiGraphQLClient({
      url: `https://mvr-rpc.sui-mainnet.mystenlabs.com/graphql`,
    }),
  })
);

export const newTransaction = () => {
  return new Transaction();
};
