import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Raw text plugin for .sql imports
function rawSql() {
  return {
    name: "raw-sql",
    transform(code: string, id: string) {
      if (id.endsWith(".sql")) {
        const content = readFileSync(id, "utf-8");
        return {
          code: `export default ${JSON.stringify(content)};`,
          map: null,
        };
      }
    },
  };
}

export default defineWorkersConfig({
  plugins: [rawSql()],
  test: {
    poolOptions: {
      workers: {
        isolatedStorage: false,
        wrangler: { configPath: "./wrangler.toml" },
      },
    },
  },
});
