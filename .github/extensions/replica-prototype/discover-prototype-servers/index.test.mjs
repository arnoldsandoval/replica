import assert from "node:assert/strict"
import { realpath } from "node:fs/promises"
import { describe, it } from "node:test"

import { withContext } from "../test-support/with-context/index.mjs"
import { discoverPrototypeServers } from "./index.mjs"

describe("discoverPrototypeServers()", () => {
  it("matches exact checkout directories and descendants, not sibling worktrees or canvas providers", async () => {
    await withContext(async (context) => {
      const root = await realpath(context.repositoryPath)
      const probed = []
      const result = await discoverPrototypeServers(root, {
        runCommand: async (command, args, cwd) => {
          assert.equal(command, "lsof")
          assert.equal(cwd, root)
          if (args.includes("-iTCP"))
            return {
              ok: true,
              stdout: `p101\ncnode\nn[::1]:5173\np102\ncnode\nn*:5174\nn*:5174\np103\ncnode\nn127.0.0.1:5175\np104\ncnode\nn127.0.0.1:5176\np105\nccopilot\nn127.0.0.1:5177\np${process.pid}\ncnode\nn127.0.0.1:5178\np106\ncnode\nn192.168.1.10:5179\n`,
            }
          assert.equal(args[args.indexOf("-p") + 1], "101,102,103,104,106")
          return {
            ok: true,
            stdout: `p101\nfcwd\nn${root}\np102\nfcwd\nn${root}/template\np103\nfcwd\nn${root}-other\np104\nfcwd\nn${root}/../sibling\np106\nfcwd\nn${root}\n`,
          }
        },
        fetch: async (url, options) => {
          assert.equal(options.redirect, "manual")
          assert.ok(options.signal instanceof AbortSignal)
          probed.push(url)
          return new Response("<html></html>", {
            headers: { "Content-Type": "text/html; charset=utf-8" },
          })
        },
      })
      assert.deepEqual(probed.sort(), ["http://127.0.0.1:5174/", "http://[::1]:5173/"].sort())
      assert.equal(result.servers.length, 2)
      assert.deepEqual(result.warnings, [])
    })
  })

  it("reports unavailable tools and failed probes without guessing or following redirects", async () => {
    await withContext(async (context) => {
      await assert.rejects(
        discoverPrototypeServers(context.repositoryPath, {
          runCommand: async () => ({ ok: false, error: "lsof is not installed." }),
        }),
        /lsof is not installed/,
      )
      const root = await realpath(context.repositoryPath)
      const result = await discoverPrototypeServers(root, {
        runCommand: async (_command, args) => ({
          ok: true,
          stdout: args.includes("-iTCP")
            ? "p101\ncnode\nn*:5000\nn*:5001\nn*:5002\n"
            : `p101\nfcwd\nn${root}\n`,
        }),
        fetch: async (url) => {
          if (url.includes(":5000")) throw new Error("Connection refused")
          if (url.includes(":5001"))
            return new Response("{}", { headers: { "Content-Type": "application/json" } })
          return new Response(null, {
            status: 302,
            headers: { Location: "https://unrelated.example/" },
          })
        },
      })
      assert.deepEqual(result.servers, [])
      assert.equal(result.warnings.length, 3)
      assert.match(result.warnings[0], /Connection refused/)
      assert.match(result.warnings[2], /HTTP 302/)
    })
  })

  it("treats no matches and vanished processes as empty results without hiding lsof errors", async () => {
    await withContext(async (context) => {
      const noMatches = { ok: false, exitCode: 1, stdout: "", stderr: "", error: "Command failed" }
      assert.deepEqual(
        await discoverPrototypeServers(context.repositoryPath, {
          runCommand: async () => noMatches,
        }),
        { servers: [], warnings: [] },
      )
      assert.deepEqual(
        await discoverPrototypeServers(context.repositoryPath, {
          runCommand: async (_command, args) =>
            args.includes("-iTCP") ? { ok: true, stdout: "p101\ncnode\nn*:5173\n" } : noMatches,
        }),
        { servers: [], warnings: [] },
      )
      await assert.rejects(
        discoverPrototypeServers(context.repositoryPath, {
          runCommand: async () => ({
            ...noMatches,
            stderr: "permission denied",
            error: "permission denied",
          }),
        }),
        /Could not inspect running servers: permission denied/,
      )
    })
  })

  it("keeps usable output when one of the selected processes has disappeared", async () => {
    await withContext(async (context) => {
      const root = await realpath(context.repositoryPath)
      const result = await discoverPrototypeServers(root, {
        runCommand: async (_command, args) =>
          args.includes("-iTCP")
            ? { ok: true, stdout: "p101\ncnode\nn*:5173\np102\ncnode\nn*:5174\n" }
            : { ok: false, exitCode: 1, stdout: `p101\nfcwd\nn${root}\n`, stderr: "" },
        fetch: async () => new Response("", { headers: { "Content-Type": "text/html" } }),
      })
      assert.deepEqual(
        result.servers.map((server) => server.url),
        ["http://127.0.0.1:5173/"],
      )
      assert.deepEqual(result.warnings, [])
    })
  })
})
