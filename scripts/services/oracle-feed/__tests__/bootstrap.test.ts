import { describe, expect, it } from "vitest";
import { assertSignerOwnsAdminCap } from "../bootstrap";

describe("assertSignerOwnsAdminCap", () => {
  it("throws a clear error when the signer does not own the admin cap", async () => {
    const client = {
      getObject: async () => ({
        data: {
          owner: {
            AddressOwner: "0xadmin",
          },
        },
      }),
    } as any;

    await expect(
      assertSignerOwnsAdminCap(client, "0xsigner", "0xcap"),
    ).rejects.toThrow(
      "oracle-feed signer 0xsigner must own AdminCap 0xcap, but current owner is 0xadmin",
    );
  });
});
