import { expect, test } from "vitest";

import { SDK_NAME } from "../src/index.js";

test("package exports", () => expect(SDK_NAME).toBe("@mysten/predict"));
