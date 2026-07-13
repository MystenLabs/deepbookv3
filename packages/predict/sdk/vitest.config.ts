import { defineConfig } from "vitest/config";

export default defineConfig({
    test: {
        include: ["tests/**/*.test.ts"],
        exclude: process.env.PREDICT_SDK_TESTNET ? [] : ["tests/testnet/**"],
    },
});
