import assert from "node:assert/strict"
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { it } from "node:test"

import { createShareControlPreferences } from "./index.mjs"

it("persists only the choice across store restarts and isolates prototype identities", async (t) => {
  const directory = await mkdtemp(path.join(tmpdir(), "replica-share-preferences-"))
  t.after(() => rm(directory, { recursive: true }))
  const preferences = createShareControlPreferences(directory)
  assert.equal(await preferences.read("hub:repository:prototype-a"), false)
  await preferences.write("hub:repository:prototype-a", true)
  const reopened = createShareControlPreferences(directory)
  assert.equal(await reopened.read("hub:repository:prototype-a"), true)
  for (const identity of [
    "hub:repository:prototype-b",
    "hub:another-repo:prototype-a",
    "another-hub:repository:prototype-a",
  ])
    assert.equal(await reopened.read(identity), false)
  await reopened.write("hub:repository:prototype-a", false)
  assert.equal(
    await createShareControlPreferences(directory).read("hub:repository:prototype-a"),
    false,
  )
  assert.equal((await readdir(directory)).length, 1)
})

it("rejects invalid writes, corrupt saved choices and unusable storage", async (t) => {
  const directory = await mkdtemp(path.join(tmpdir(), "replica-share-preferences-"))
  t.after(() => rm(directory, { recursive: true }))
  const preferences = createShareControlPreferences(directory)
  await assert.rejects(preferences.write("prototype", "true"), /Invalid share preference/)
  await preferences.write("prototype", true)
  const [file] = await readdir(directory)
  await writeFile(path.join(directory, file), '"not a boolean"', { mode: 0o600 })
  await assert.rejects(preferences.read("prototype"), /Invalid saved share preference/)
  await writeFile(path.join(directory, file), "{invalid", { mode: 0o600 })
  await assert.rejects(preferences.read("prototype"), SyntaxError)
  const unavailable = createShareControlPreferences(path.join(directory, file))
  await assert.rejects(unavailable.read("prototype"))
  await assert.rejects(unavailable.write("prototype", true))
})
