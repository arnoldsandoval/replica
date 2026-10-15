import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { checkPrototypeServer } from "./index.mjs"

describe("checkPrototypeServer()", () => {
  it("keeps HTTP errors and redirects visible in the preview without reading response bodies", async () => {
    for (const status of [200, 302, 404, 500]) {
      const response = new Response("Preview", { status })
      const result = await checkPrototypeServer(
        "http://localhost:5173/demo#/actions",
        async (url, options) => {
          assert.equal(url, "http://localhost:5173/demo#/actions")
          assert.equal(options.redirect, "manual")
          assert.ok(options.signal instanceof AbortSignal)
          return response
        },
      )
      assert.deepEqual(result, { available: true })
      assert.equal(response.bodyUsed, true)
    }
  })

  it("reports failed connections and timeouts as unavailable", async () => {
    for (const message of ["Connection refused", "Request timed out"]) {
      const result = await checkPrototypeServer("http://localhost:5173/", async () => {
        throw new Error(message)
      })
      assert.equal(result.available, false)
      assert.match(result.message, /Start it again or choose another server/)
      assert.ok(result.message.includes(message))
    }
  })
})
