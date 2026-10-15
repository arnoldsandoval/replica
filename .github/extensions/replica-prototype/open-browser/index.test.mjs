import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { openBrowser } from "./index.mjs"

describe("openBrowser()", () => {
  it("opens the approval URL with the host browser without shell interpolation", async () => {
    const url = "https://hub.example.com/canvas/pair/ABCD"
    for (const [platform, command, args] of [
      ["darwin", "open", [url]],
      ["win32", "rundll32", ["url.dll,FileProtocolHandler", url]],
      ["linux", "xdg-open", [url]],
    ]) {
      let calls = 0
      const result = await openBrowser(url, {
        platform,
        run: async (actualCommand, actualArgs) => {
          calls += 1
          assert.equal(actualCommand, command)
          assert.deepEqual(actualArgs, args)
          return { ok: true, stdout: "" }
        },
      })
      assert.equal(calls, 1)
      assert.equal(result.ok, true)
    }
  })

  it("reports browser launch failure and rejects non-web approval URLs", async () => {
    const failure = { ok: false, error: "No browser available." }
    assert.deepEqual(
      await openBrowser("https://hub.example.com/canvas/pair/ABCD", {
        run: async () => failure,
      }),
      failure,
    )
    await assert.rejects(openBrowser("file:///etc/passwd"), /HTTP or HTTPS/)
    await assert.rejects(
      openBrowser("https://user:password@hub.example.com"),
      /without credentials/,
    )
  })
})
