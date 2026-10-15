import assert from "node:assert/strict"
import { readdir, writeFile } from "node:fs/promises"
import path from "node:path"
import { describe, it } from "node:test"

import { withContext } from "../test-support/with-context/index.mjs"
import { prototypeConnection } from "./index.mjs"

describe("prototypeConnection()", () => {
  it("remembers a connection only in its owning session and checkout", async () => {
    await withContext(async (context) => {
      const store = prototypeConnection(context.sessionWorkspacePath, context.repositoryPath)
      assert.equal(await store.read(), null)
      const input = { prototypeUrl: "http://localhost:5173/#/actions", name: "Demo" }
      await store.save(input)
      assert.deepEqual(
        await prototypeConnection(context.sessionWorkspacePath, context.repositoryPath).read(),
        input,
      )
      assert.equal(
        await prototypeConnection(
          context.sessionWorkspacePath,
          `${context.repositoryPath}/other`,
        ).read(),
        null,
      )
      assert.equal(
        await prototypeConnection(
          `${context.sessionWorkspacePath}/other`,
          context.repositoryPath,
        ).read(),
        null,
      )
      const file = (await readdir(context.stateDirectory)).find((name) =>
        name.startsWith("connection-"),
      )
      await writeFile(path.join(context.stateDirectory, file), "invalid JSON")
      await assert.rejects(store.read(), SyntaxError)
    })
  })
})
