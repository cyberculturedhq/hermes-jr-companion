// Keep the independent feed environment out of the relay's global Env namespace.
require("node:fs").appendFileSync("release-feed-configuration.d.ts", "\nexport { ReleaseFeedEnv };\n");
for (const path of ["worker-configuration.d.ts", "release-feed-configuration.d.ts"]) {
  const fs = require("node:fs");
  fs.writeFileSync(path, fs.readFileSync(path, "utf8").replace(/[ \t]+$/gm, ""));
}
