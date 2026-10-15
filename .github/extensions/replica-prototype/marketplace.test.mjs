import assert from "node:assert/strict"
import { readFile, realpath } from "node:fs/promises"
import { it } from "node:test"

it("resolves the marketplace's relative source to the shipped plugin", async () => {
  const root = new URL("../../../", import.meta.url)
  const catalog = JSON.parse(await readFile(new URL(".github/plugin/marketplace.json", root)))
  assert.equal(catalog.name, "replica")
  assert.equal(catalog.plugins.length, 1)
  const plugin = catalog.plugins[0]
  assert.equal(plugin.name, "replica-prototype")
  assert.equal(plugin.source, "./.github/extensions/replica-prototype")
  assert.equal(
    await realpath(new URL(plugin.source, root)),
    await realpath(new URL(".", import.meta.url)),
  )
  const manifest = JSON.parse(await readFile(new URL(`${plugin.source}/plugin.json`, root)))
  assert.equal(manifest.name, plugin.name)
  assert.equal(manifest.version, "1.2.0")
})
