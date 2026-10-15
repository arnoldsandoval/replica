import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { it } from "node:test"

it("fails the demo when a successful command fails or a forbidden export succeeds", () => {
  const cli = new URL("../src/cli.mjs", import.meta.url).href
  const demo = new URL("../examples/demo.mjs", import.meta.url).href
  for (const [command, returned, expected] of [
    ["accept", 1, 0],
    ["recall", 1, 0],
    ["verify", 1, 0],
    ["export", 0, 1],
  ]) {
    const replacement = `
      import { main as actual } from ${JSON.stringify(`${cli}?original`)};
      export async function main(args, io) {
        const code = await actual(args, io);
        return args[0] === ${JSON.stringify(command)} ? ${returned} : code;
      }
    `
    const script = `
      import { registerHooks } from "node:module";
      registerHooks({
        load(url, context, nextLoad) {
          return url === ${JSON.stringify(cli)}
            ? { format: "module", source: ${JSON.stringify(replacement)}, shortCircuit: true }
            : nextLoad(url, context);
        }
      });
      await import(${JSON.stringify(demo)});
    `
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", script], {
      encoding: "utf8",
      timeout: 30_000,
    })
    assert.ifError(result.error)
    assert.equal(result.status, 1, command)
    assert.match(result.stderr, new RegExp(`${command} returned ${returned}, expected ${expected}`))
  }
})
