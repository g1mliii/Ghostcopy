import { defineConfig } from "cf/config";

// ghostcopy.app as a Worker with static assets - Cloudflare's successor to
// Pages, which the `cf` CLI deploys (`cf pages deploy` refuses Pages
// projects). The site is plain files: no Worker code, only assets.
//
// What gets uploaded is set in wrangler.config.ts, and it must stay ./dist.
// Left to itself, cf's autoconfig picked the whole website folder -
// node_modules and all.
export default defineConfig({
  worker: {
    name: "ghostcopy-website",
    compatibilityDate: "2026-09-29",
    assets: {
      // /download serves download.html, as it did on Pages.
      htmlHandling: "auto-trailing-slash",
      notFoundHandling: "404-page",
    },
    domains: ["ghostcopy.app", "www.ghostcopy.app"],
    observability: { enabled: true },
  },
});
