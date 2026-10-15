import assert from "node:assert/strict"
import { chmod, readFile, readdir, stat, writeFile } from "node:fs/promises"
import path from "node:path"
import { it } from "node:test"

import { withContext } from "../test-support/with-context/index.mjs"
import { createPublishPreferences } from "./index.mjs"

it("remembers an explicit opt-in privately per repository and branch across instances and supports resetting", async () => {
  await withContext(async (context) => {
    const directory = path.join(context.sessionWorkspacePath, "preferences")
    const preferences = createPublishPreferences(directory)
    const target = { repository: "github/replica", branch: "prototype" }
    assert.equal(await preferences.read(target), false)
    await preferences.write(target, true)
    const reopened = createPublishPreferences(directory)
    assert.equal(await reopened.read({ ...target, repository: "GitHub/Replica" }), true)
    assert.equal(await reopened.read({ ...target, repository: "github/another" }), false)
    assert.equal(await reopened.read({ ...target, branch: "prototype/another" }), false)
    assert.equal(await reopened.read({ ...target, branch: "Prototype" }), false)
    const file = path.join(directory, (await readdir(directory))[0])
    assert.equal((await stat(directory)).mode & 0o077, 0)
    assert.equal((await stat(file)).mode & 0o077, 0)
    assert.equal(await readFile(file, "utf8"), "true")
    await reopened.write(target, false)
    assert.equal(await preferences.read(target), false)
    await writeFile(file, '"invalid"')
    await assert.rejects(preferences.read(target), /Invalid saved/)
    await chmod(file, 0o644)
    await assert.rejects(preferences.read(target), /not private/)
    await assert.rejects(preferences.write(target, "true"), /Invalid publishing/)
    await assert.rejects(preferences.read({ repository: target.repository }), /verified branch/)
  })
})
