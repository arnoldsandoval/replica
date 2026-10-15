import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { mkdir, readFile, symlink, writeFile } from "node:fs/promises"
import path from "node:path"
import { describe, it } from "node:test"
import { setTimeout as delay } from "node:timers/promises"

import { createPrivateStore } from "../private-store/index.mjs"
import { runCommand } from "../run-command/index.mjs"
import { STARTUP_ERROR, StartupError } from "../startup-error/index.mjs"
import { withContext } from "../test-support/with-context/index.mjs"
import { createDevServerManager, readDevScripts } from "./index.mjs"

async function manifest(directory, value = { scripts: { dev: "vite" } }) {
  await writeFile(path.join(directory, "package.json"), JSON.stringify(value))
}

function fixtureManager(directory, options = {}) {
  let child
  let url
  let launches = 0
  const manager = createDevServerManager({
    store: createPrivateStore(path.join(directory, "locks")),
    pollInterval: 10,
    timeout: 3000,
    launch(executable, args, settings) {
      assert.equal(executable, "npm")
      assert.deepEqual(args, ["run", "dev"])
      assert.equal(settings.env.COREPACK_ENABLE_NETWORK, "0")
      launches += 1
      url = undefined
      child = spawn(
        process.execPath,
        [
          "--input-type=module",
          "-e",
          `
        import { createServer } from "node:http"
        ${options.linger ? 'process.on("SIGTERM", () => {})' : ""}
        const server = createServer((req, res) => {
          res.setHeader("Content-Type", "text/html")
          res.end("<h1>Prototype ready</h1>")
        })
        server.listen(0, "127.0.0.1", () => {
          process.stdout.write("http://127.0.0.1:" + server.address().port + "/\\n")
        })
      `,
        ],
        settings,
      )
      child.stdout.on("data", (chunk) => {
        url = chunk.toString().trim()
      })
      return child
    },
    async discover() {
      const servers = [{ url: "http://127.0.0.1:9999/", pid: 999999, command: "unrelated" }]
      if (!child || child.exitCode !== null || child.signalCode !== null)
        return { servers: [], warnings: [] }
      if (url && (await fetch(url)).ok) servers.push({ url, pid: child.pid, command: "node" })
      return { servers, warnings: [] }
    },
    ...options,
  })
  return { manager, child: () => child, launches: () => launches }
}

describe("readDevScripts()", () => {
  it("shows the script, directory and lifecycle hooks without executing anything", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath, {
        scripts: { dev: "vite --host 127.0.0.1", predev: "node prepare.mjs", postdev: "echo done" },
      })
      const { scripts } = await readDevScripts(repositoryPath)
      assert.equal(scripts.length, 1)
      assert.equal(scripts[0].invocation, "npm run dev")
      assert.equal(scripts[0].directory, repositoryPath)
      assert.deepEqual(scripts[0].hooks, ["predev: node prepare.mjs", "postdev: echo done"])
      assert.match(scripts[0].id, /^[a-f0-9]{64}:dev$/)
    })
  })

  it("uses the declared package manager or lockfile and rejects conflicts", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      await writeFile(path.join(repositoryPath, "pnpm-lock.yaml"), "")
      assert.equal((await readDevScripts(repositoryPath)).scripts[0].invocation, "pnpm run dev")
      await manifest(repositoryPath, { packageManager: "pnpm@10.0.0", scripts: { dev: "vite" } })
      assert.equal((await readDevScripts(repositoryPath)).scripts[0].manager, "pnpm")
      await writeFile(path.join(repositoryPath, "package-lock.json"), "{}")
      await assert.rejects(readDevScripts(repositoryPath), /Conflicting package managers/)
    })
  })

  it("offers multiple explicit choices, not production starts or compound commands", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath, {
        scripts: { dev: "next dev", start: "next start", serve: "vite preview" },
      })
      assert.deepEqual(
        (await readDevScripts(repositoryPath)).scripts.map((script) => script.name),
        ["dev"],
      )
      await manifest(repositoryPath, {
        scripts: {
          dev: "vite && touch marker",
          start: "react-scripts start",
          serve: "webpack serve",
        },
      })
      assert.deepEqual(
        (await readDevScripts(repositoryPath)).scripts.map((script) => script.name),
        ["start", "serve"],
      )
    })
  })

  it("does not traverse packages or follow linked manifests and reports invalid JSON", async () => {
    await withContext(async ({ repositoryPath }) => {
      await mkdir(path.join(repositoryPath, "app"))
      await manifest(path.join(repositoryPath, "app"))
      assert.deepEqual((await readDevScripts(repositoryPath)).scripts, [])
      await symlink("app/package.json", path.join(repositoryPath, "package.json"))
      await assert.rejects(readDevScripts(repositoryPath), /linked/)
    })
    await withContext(async ({ repositoryPath }) => {
      await writeFile(path.join(repositoryPath, "package.json"), "{broken")
      await assert.rejects(readDevScripts(repositoryPath), /not valid JSON/)
    })
  })
})

describe("createDevServerManager()", () => {
  it("runs a real npm script and its lifecycle hook, discovers its child and stops it on shutdown", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath, {
        scripts: { dev: "vite", predev: "echo Preparing prototype" },
      })
      const bin = path.join(repositoryPath, "node_modules", ".bin")
      await mkdir(bin, { recursive: true })
      await writeFile(
        path.join(bin, "vite"),
        `#!/usr/bin/env node
const { createServer } = require("node:http")
const { writeFileSync } = require("node:fs")
const server = createServer((req, res) => {
  res.setHeader("Content-Type", "text/html")
  res.end("<h1>npm prototype</h1>")
})
server.listen(0, "127.0.0.1", () => {
  writeFileSync("listener.json", JSON.stringify({
    url: "http://127.0.0.1:" + server.address().port + "/",
    pid: process.pid,
    command: "node"
  }))
})
`,
        { mode: 0o755 },
      )
      const manager = createDevServerManager({
        store: createPrivateStore(path.join(repositoryPath, "locks")),
        pollInterval: 20,
        timeout: 10_000,
        async discover() {
          let listener
          try {
            listener = JSON.parse(
              await readFile(path.join(repositoryPath, "listener.json"), "utf8"),
            )
          } catch (error) {
            if (error.code !== "ENOENT") throw error
            return { servers: [], warnings: [] }
          }
          assert.equal((await fetch(listener.url)).headers.get("content-type"), "text/html")
          return { servers: [listener], warnings: [] }
        },
      })
      try {
        const lease = await manager.acquire(repositoryPath)
        const url = await lease.start((await lease.describe()).scripts[0].id)
        assert.match(await (await fetch(url)).text(), /npm prototype/)
        assert.match(lease.status().output, /Preparing prototype/)
        await manager.close()
        await assert.rejects(fetch(url))
      } finally {
        await manager.close()
      }
    })
  })

  it("starts only on request, shares concurrent starts, connects to the owned listener and stops on last close", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const fixture = fixtureManager(repositoryPath)
      const first = await fixture.manager.acquire(repositoryPath)
      const second = await fixture.manager.acquire(repositoryPath)
      try {
        const { scripts } = await first.describe()
        assert.equal(fixture.launches(), 0)
        const [url, otherUrl] = await Promise.all([
          first.start(scripts[0].id),
          second.start(scripts[0].id),
        ])
        assert.equal(url, otherUrl)
        assert.equal(fixture.launches(), 1)
        assert.match(await (await fetch(url)).text(), /Prototype ready/)
        assert.match(first.status().output, /http:\/\/127.0.0.1:/)
        await first.release()
        assert.equal((await fetch(url)).status, 200)
        await second.release()
        await assert.rejects(fetch(url))
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("reuses an existing server without launching or stopping it", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const fixture = fixtureManager(repositoryPath, {
        discover: async () => ({
          servers: [{ url: "http://127.0.0.1:5173/", pid: 17 }],
          warnings: [],
        }),
      })
      const lease = await fixture.manager.acquire(repositoryPath)
      try {
        const { scripts } = await lease.describe()
        assert.equal(await lease.start(scripts[0].id), "http://127.0.0.1:5173/")
        assert.equal(fixture.launches(), 0)
      } finally {
        await lease.release()
        await fixture.manager.close()
      }
    })
  })

  it("rejects stale consent and missing managers without spawning", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const fixture = fixtureManager(repositoryPath, {
        command: async () => ({ ok: false }),
      })
      const lease = await fixture.manager.acquire(repositoryPath)
      try {
        const { scripts } = await lease.describe()
        await manifest(repositoryPath, { scripts: { dev: "vite --port 4321" } })
        await assert.rejects(lease.start(scripts[0].id), /Dev scripts changed/)
        const current = await lease.describe()
        await assert.rejects(lease.start(current.scripts[0].id), /npm is unavailable/)
        assert.equal(fixture.launches(), 0)
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("preserves failure output and lets a failed start be retried", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      let attempts = 0
      const fixture = fixtureManager(repositoryPath, {
        launch(_executable, _args, settings) {
          attempts += 1
          return spawn(
            process.execPath,
            ["-e", "process.stderr.write('vite: missing dependency\\n'); process.exit(2)"],
            settings,
          )
        },
        discover: async () => ({ servers: [], warnings: [] }),
      })
      const lease = await fixture.manager.acquire(repositoryPath)
      try {
        const { scripts } = await lease.describe()
        await assert.rejects(lease.start(scripts[0].id), /exited \(code 2\)/)
        assert.match(lease.status().output, /missing dependency/)
        assert.equal(lease.status().starting, false)
        await assert.rejects(lease.start(scripts[0].id), /exited \(code 2\)/)
        assert.equal(attempts, 2)
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("times out unrelated listeners and terminates its process group", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      let child
      const fixture = fixtureManager(repositoryPath, {
        timeout: 100,
        launch(_executable, _args, settings) {
          child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], settings)
          return child
        },
        discover: async () => ({ servers: [], warnings: [] }),
      })
      const lease = await fixture.manager.acquire(repositoryPath)
      try {
        const { scripts } = await lease.describe()
        await assert.rejects(lease.start(scripts[0].id), /did not serve an HTML page/)
        assert.throws(() => process.kill(child.pid, 0), { code: "ESRCH" })
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("passes a no-download environment to the package-manager preflight", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const fixture = fixtureManager(repositoryPath, {
        command(executable, args, cwd, options) {
          if (args[0] === "--version") {
            assert.equal(options.env.COREPACK_ENABLE_NETWORK, "0")
            return Promise.resolve({ ok: true })
          }
          return runCommand(executable, args, cwd)
        },
      })
      const lease = await fixture.manager.acquire(repositoryPath)
      try {
        await lease.start((await lease.describe()).scripts[0].id)
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("rescans after preflight and reuses a newly ready manual listener", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      let preflightFinished = false
      const fixture = fixtureManager(repositoryPath, {
        command: async () => {
          preflightFinished = true
          return { ok: true }
        },
        discover: async () => ({
          servers: preflightFinished ? [{ url: "http://127.0.0.1:5173/", pid: 17 }] : [],
          warnings: [],
        }),
      })
      try {
        const lease = await fixture.manager.acquire(repositoryPath)
        assert.equal(
          await lease.start((await lease.describe()).scripts[0].id),
          "http://127.0.0.1:5173/",
        )
        assert.equal(fixture.launches(), 0)
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("requires selection when multiple listeners become ready during preflight", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      let preflightFinished = false
      const fixture = fixtureManager(repositoryPath, {
        command: async () => {
          preflightFinished = true
          return { ok: true }
        },
        discover: async () => ({
          servers: preflightFinished
            ? [
                { url: "http://127.0.0.1:5173/", pid: 17 },
                { url: "http://127.0.0.1:5174/", pid: 18 },
              ]
            : [],
          warnings: [],
        }),
      })
      try {
        const lease = await fixture.manager.acquire(repositoryPath)
        await assert.rejects(lease.start((await lease.describe()).scripts[0].id), /choose one/)
        assert.equal(fixture.launches(), 0)
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("waits for last-panel teardown before reacquiring the checkout", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const fixture = fixtureManager(repositoryPath, { linger: true })
      try {
        const first = await fixture.manager.acquire(repositoryPath)
        const id = (await first.describe()).scripts[0].id
        const oldUrl = await first.start(id)
        const oldChild = fixture.child()
        const releasing = first.release()
        const replacement = await fixture.manager.acquire(repositoryPath)
        assert.throws(() => process.kill(oldChild.pid, 0), { code: "ESRCH" })
        await releasing
        const newUrl = await replacement.start(id)
        assert.notEqual(newUrl, oldUrl)
        assert.equal(fixture.launches(), 2)
        assert.equal((await fetch(newUrl)).status, 200)
      } finally {
        await fixture.manager.close()
      }
    })
  })

  it("holds the checkout lock during normal last-lease teardown across providers", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const store = createPrivateStore(path.join(repositoryPath, "locks"))
      let lockCalls = 0
      let retiring
      const retirementStarted = new Promise((resolve) => {
        retiring = resolve
      })
      const first = fixtureManager(repositoryPath, {
        linger: true,
        store: {
          lock(name, action) {
            lockCalls += 1
            return store.lock(name, () => {
              if (lockCalls === 2) retiring()
              return action()
            })
          },
        },
      })
      let oldUrl
      const second = fixtureManager(repositoryPath, {
        discover: async () => ({
          servers:
            first.child()?.signalCode === null && first.child()?.exitCode === null
              ? [{ url: oldUrl, pid: first.child().pid }]
              : [],
          warnings: [],
        }),
        command: async () => ({ ok: false }),
      })
      try {
        const firstLease = await first.manager.acquire(repositoryPath)
        const secondLease = await second.manager.acquire(repositoryPath)
        const id = (await firstLease.describe()).scripts[0].id
        oldUrl = await firstLease.start(id)
        const releasing = firstLease.release()
        await Promise.race([
          retirementStarted,
          delay(3000).then(() => {
            throw new Error("Locked teardown did not start")
          }),
        ])
        assert.equal((await fetch(oldUrl)).status, 200)
        await assert.rejects(secondLease.start(id), /npm is unavailable/)
        await releasing
        assert.throws(() => process.kill(first.child().pid, 0), { code: "ESRCH" })
      } finally {
        await Promise.all([first.manager.close(), second.manager.close()])
      }
    })
  })

  it("cancels pending startup before taking the last-lease teardown lock", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      let polling
      let resume
      const pollingStarted = new Promise((resolve) => {
        polling = resolve
      })
      const continuePolling = new Promise((resolve) => {
        resume = resolve
      })
      const fixture = fixtureManager(repositoryPath, {
        command: async (executable, args, cwd, options) => {
          if (executable === "ps") {
            polling()
            await continuePolling
          }
          return runCommand(executable, args, cwd, options)
        },
      })
      try {
        const lease = await fixture.manager.acquire(repositoryPath)
        const id = (await lease.describe()).scripts[0].id
        const failedStart = assert.rejects(lease.start(id), /prototype panel was closed/)
        await pollingStarted
        const releasing = lease.release()
        const acquiring = fixture.manager.acquire(repositoryPath)
        resume()
        await Promise.all([failedStart, releasing])
        const replacement = await acquiring
        assert.equal(replacement.status().starting, false)
        assert.equal(fixture.launches(), 1)
        assert.throws(() => process.kill(fixture.child().pid, 0), { code: "ESRCH" })
      } finally {
        resume()
        await fixture.manager.close()
      }
    })
  })

  it("keeps the cross-provider lock until failed startup teardown finishes", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      let child
      let oldUrl
      let stopping
      const stopped = new Promise((resolve) => {
        stopping = resolve
      })
      const first = fixtureManager(repositoryPath, {
        discover: async () => {
          if (oldUrl) throw new StartupError("Startup readiness failed")
          return { servers: [], warnings: [] }
        },
        launch(_executable, _args, settings) {
          child = spawn(
            process.execPath,
            [
              "--input-type=module",
              "-e",
              `
              import { createServer } from "node:http"
              process.on("SIGTERM", () => process.stdout.write("stopping\\n"))
              createServer((req, res) => res.end("old listener")).listen(0, "127.0.0.1", function () {
                process.stdout.write("http://127.0.0.1:" + this.address().port + "/\\n")
              })
            `,
            ],
            settings,
          )
          child.stdout.on("data", (chunk) => {
            for (const line of chunk.toString().trim().split("\n")) {
              if (line === "stopping") stopping()
              else oldUrl = line
            }
          })
          return child
        },
      })
      const second = fixtureManager(repositoryPath, {
        async discover() {
          if (child && child.exitCode === null && child.signalCode === null && oldUrl)
            return { servers: [{ url: oldUrl, pid: child.pid }], warnings: [] }
          return { servers: [], warnings: [] }
        },
        command: async () => ({ ok: false }),
      })
      try {
        const firstLease = await first.manager.acquire(repositoryPath)
        const secondLease = await second.manager.acquire(repositoryPath)
        const id = (await firstLease.describe()).scripts[0].id
        const failure = assert.rejects(firstLease.start(id), /Startup readiness failed/)
        await Promise.race([
          stopped,
          delay(3000).then(() => {
            throw new Error("Teardown did not start")
          }),
        ])
        assert.equal((await fetch(oldUrl)).status, 200)
        await assert.rejects(secondLease.start(id), /npm is unavailable/)
        await failure
        assert.throws(() => process.kill(child.pid, 0), { code: "ESRCH" })
      } finally {
        await Promise.all([first.manager.close(), second.manager.close()])
      }
    })
  })

  it("filters unexpected startup failures in status while preserving intentional errors", async () => {
    await withContext(async ({ repositoryPath }) => {
      await manifest(repositoryPath)
      const rawError = new Error("secret=DO_NOT_EXPOSE at /private/checkout/server.mjs")
      const fixture = fixtureManager(repositoryPath, {
        discover: async () => {
          throw rawError
        },
      })
      try {
        const lease = await fixture.manager.acquire(repositoryPath)
        await assert.rejects(lease.start((await lease.describe()).scripts[0].id), rawError)
        assert.equal(lease.status().message, STARTUP_ERROR)
        assert.doesNotMatch(JSON.stringify(lease.status()), /DO_NOT_EXPOSE|private\/checkout/)
        await manifest(repositoryPath, { scripts: { dev: "vite --port 4321" } })
        await assert.rejects(lease.start("stale:dev"), StartupError)
        assert.match(lease.status().message, /Dev scripts changed/)
      } finally {
        await fixture.manager.close()
      }
    })
  })
})
