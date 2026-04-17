import { describe, expect, it } from "vitest";
import { resolveSuiBinary } from "../../utils/utils.js";

describe("resolveSuiBinary", () => {
  it("prefers an explicit SUI_BINARY override", () => {
    expect(
      resolveSuiBinary({
        envBinary: "/custom/sui",
        candidates: ["/Users/test/.local/bin/sui", "sui"],
        getVersion: () => "sui 1.68.1-test",
      }),
    ).toBe("/custom/sui");
  });

  it("prefers the newest installed binary when PATH resolves to an older sui", () => {
    const versions = new Map<string, string>([
      ["/Users/test/.local/bin/sui", "sui 1.68.1-test"],
      ["/Users/test/.cargo/bin/sui", "sui 1.52.3-test"],
      ["sui", "sui 1.28.3-homebrew"],
    ]);

    expect(
      resolveSuiBinary({
        candidates: ["/Users/test/.local/bin/sui", "/Users/test/.cargo/bin/sui", "sui"],
        getVersion: (binary) => versions.get(binary) ?? null,
      }),
    ).toBe("/Users/test/.local/bin/sui");
  });
});
