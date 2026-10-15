import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const script = join(root, "starter/scripts/setup-replica-plugin.mjs")
const installed = {
  name: "replica-prototype",
  marketplace: "replica",
  source: "installed",
  enabled: true,
}
const pluginList = ["plugin", "list", "--json"]
const marketplaceList = ["plugin", "marketplace", "list", "--json"]
const install = ["plugin", "install", "replica-prototype@replica"]
const enable = ["plugin", "enable", "replica-prototype@replica"]

function run(t, steps, { missingCli = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "replica-plugin-test-"))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const state = join(directory, "state.json")
  writeFileSync(state, JSON.stringify(steps))
  if (!missingCli) {
    writeFileSync(
      join(directory, "copilot"),
      `#!${process.execPath}
const assert = require("node:assert/strict")
const fs = require("node:fs")
const steps = JSON.parse(fs.readFileSync(process.env.REPLICA_TEST_STATE, "utf8"))
const step = steps.shift()
assert.ok(step, "Unexpected extra CLI call")
assert.deepEqual(process.argv.slice(2), step.args)
fs.writeFileSync(process.env.REPLICA_TEST_STATE, JSON.stringify(steps))
if (step.error) {
  console.error(step.error)
  process.exit(1)
}
console.log(step.raw ?? JSON.stringify(step.result ?? []))
`,
      { mode: 0o755 },
    )
  }
  const result = spawnSync(process.execPath, [script], {
    cwd: directory,
    encoding: "utf8",
    timeout: 10_000,
    env: { PATH: directory, REPLICA_TEST_STATE: state },
  })
  assert.ifError(result.error)
  assert.deepEqual(JSON.parse(readFileSync(state, "utf8")), [], result.stderr)
  return result
}

test("an enabled plugin exits silently after one local check", (t) => {
  const result = run(t, [{ args: pluginList, result: [installed] }])
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, "")
  assert.equal(result.stderr, "")
})

test("a disabled plugin is enabled and verified without marketplace or network commands", (t) => {
  const result = run(t, [
    { args: pluginList, result: [{ ...installed, enabled: false }] },
    { args: enable },
    { args: pluginList, result: [installed] },
  ])
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /future sessions/)
  assert.match(result.stdout, /both the Replica plugin and the Replica extension/)
})

test("a missing plugin registers the marketplace, installs and verifies", (t) => {
  const result = run(t, [
    { args: pluginList, result: [] },
    { args: marketplaceList, result: [] },
    { args: ["plugin", "marketplace", "add", "github/replica"] },
    { args: install },
    { args: pluginList, result: [installed] },
  ])
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /fresh Copilot session/)
})

for (const source of [
  "GitHub: github/replica",
  "GitHub: github/replica#main",
  "GitHub: github/replica#hub-v1.0.0",
]) {
  test(`installation preserves the registered source ${source}`, (t) => {
    const result = run(t, [
      { args: pluginList, result: [] },
      { args: marketplaceList, result: [{ name: "replica", source }] },
      { args: install },
      { args: pluginList, result: [installed] },
    ])
    assert.equal(result.status, 0, result.stderr)
  })
}

test("conflicting or unverifiable marketplace sources stop before installation", (t) => {
  for (const source of ["GitHub: other/replica", "GitHub: github/replica-other", undefined]) {
    const result = run(t, [
      { args: pluginList, result: [] },
      { args: marketplaceList, result: [{ name: "replica", source }] },
    ])
    assert.equal(result.status, 1)
    assert.match(result.stderr, /marketplace source could not be verified/)
  }
})

test("direct, external and duplicate installations are left unchanged", (t) => {
  for (const plugins of [
    [{ ...installed, marketplace: "" }],
    [{ ...installed, source: "external" }],
    [installed, installed],
  ]) {
    const result = run(t, [{ args: pluginList, result: plugins }])
    assert.equal(result.status, 1)
    assert.match(result.stderr, /different or ambiguous Replica installation/)
  }
})

test("missing CLI and malformed lists report setup failure with recovery guidance", (t) => {
  for (const options of [
    { steps: [], missingCli: true },
    { steps: [{ args: pluginList, raw: "not json" }] },
    { steps: [{ args: pluginList, result: {} }] },
  ]) {
    const result = run(t, options.steps, options)
    assert.equal(result.status, 1)
    assert.match(result.stderr, /Replica plugin setup failed/)
    assert.match(result.stderr, /Customization, select Installed/)
  }
})

test("CLI failures stop setup without retrying or hiding the cause", (t) => {
  for (const command of ["list", "marketplace", "install", "enable"]) {
    let steps
    if (command === "list") {
      steps = [{ args: pluginList, error: "CLI access denied" }]
    } else if (command === "enable") {
      steps = [
        { args: pluginList, result: [{ ...installed, enabled: false }] },
        { args: enable, error: "CLI access denied" },
      ]
    } else {
      steps = [
        { args: pluginList, result: [] },
        { args: marketplaceList, result: [] },
        {
          args: ["plugin", "marketplace", "add", "github/replica"],
          ...(command === "marketplace" ? { error: "CLI access denied" } : {}),
        },
        ...(command === "install" ? [{ args: install, error: "CLI access denied" }] : []),
      ]
    }
    const result = run(t, steps)
    assert.equal(result.status, 1)
    assert.match(result.stderr, /CLI access denied/)
    assert.equal(result.stdout, "")
  }
})

test("setup rejects a missing or disabled plugin after CLI success", (t) => {
  for (const plugins of [[], [{ ...installed, enabled: false }]]) {
    const result = run(t, [
      { args: pluginList, result: [{ ...installed, enabled: false }] },
      { args: enable },
      { args: pluginList, result: plugins },
    ])
    assert.equal(result.status, 1)
    assert.match(result.stderr, /did not report the Replica plugin installed and enabled/)
  }
})

test("session startup checks the plugin before installing dependencies", () => {
  const config = readFileSync(join(root, "starter/.github/github-app.yml"), "utf8")
  assert.match(config, /command: node scripts\/setup-replica-plugin\.mjs && npm ci/)
  assert.match(config, /triggers:\n\s+- session\.create/)
})
