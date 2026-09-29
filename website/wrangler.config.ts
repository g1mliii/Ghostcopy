import { defineWranglerConfig } from "wrangler/experimental-config";

// The build output, and only that. See cloudflare.config.ts.
export default defineWranglerConfig({
  assetsDirectory: "./dist",
});
