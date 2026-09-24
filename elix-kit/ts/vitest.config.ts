import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    // Tests are offline; do not try to spin up any RPC.
    testTimeout: 5000,
  },
});
