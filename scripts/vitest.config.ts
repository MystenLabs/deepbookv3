import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["services/**/__tests__/**/*.test.ts"],
    environment: "node",
    passWithNoTests: true,
  },
});
