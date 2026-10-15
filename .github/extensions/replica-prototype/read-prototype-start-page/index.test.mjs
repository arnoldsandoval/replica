import assert from "node:assert/strict"
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { it } from "node:test"

import { parsePrototypeStartPage, readPrototypeStartPage } from "./index.mjs"

it("reads a working-tree start page without requiring a commit or Hub", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "replica-start-page-"))
  try {
    assert.deepEqual(await readPrototypeStartPage(root), { localStartPage: null })
    await writeFile(path.join(root, ".prototype"), JSON.stringify({ startPage: "/#/activity?q=1" }))
    assert.deepEqual(await readPrototypeStartPage(root), { localStartPage: "/#/activity?q=1" })
    await writeFile(
      path.join(root, ".prototype"),
      JSON.stringify({ startPage: "/" }).padEnd(16_384),
    )
    assert.deepEqual(await readPrototypeStartPage(root), { localStartPage: "/" })
    await writeFile(path.join(root, ".prototype"), "{invalid")
    assert.match((await readPrototypeStartPage(root)).localStartPageError, /Could not read/)
    await writeFile(path.join(root, ".prototype"), "x".repeat(16_385))
    assert.match((await readPrototypeStartPage(root)).localStartPageError, /16 KiB/)
    await rm(path.join(root, ".prototype"))
    await symlink("outside.json", path.join(root, ".prototype"))
    assert.match((await readPrototypeStartPage(root)).localStartPageError, /Could not read/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

it("accepts local routes and ignores legacy fields", () => {
  for (const route of [
    "/",
    "/settings?q=a%20b#details",
    "/#/activity",
    "/hello%20world",
    "/" + "a".repeat(2047),
  ]) {
    assert.equal(parsePrototypeStartPage(JSON.stringify({ startPage: route, name: "Old" })), route)
  }
})

it("rejects malformed metadata and unsafe routes before browser normalization", () => {
  for (const value of [
    null,
    [],
    {},
    { startPage: 7 },
    ...[
      "",
      "relative",
      "//evil.test",
      "https://evil.test",
      "/a/../b",
      "/a/%2e/b",
      "/%FF",
      "/%2fhost",
      "/%09/host",
      "/__replica",
      "/a\\b",
      "/a b",
      "/a\nb",
      "/" + "a".repeat(2048),
    ].map((startPage) => ({ startPage })),
  ]) {
    assert.throws(() => parsePrototypeStartPage(JSON.stringify(value)))
  }
})
