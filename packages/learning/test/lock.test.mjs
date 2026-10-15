import assert from "node:assert/strict"
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs"
import { open } from "node:fs/promises"
import { hostname, tmpdir } from "node:os"
import path from "node:path"
import { after, describe, it } from "node:test"
import { createFileLock } from "../src/providers/lock.mjs"

const work = mkdtempSync(path.join(tmpdir(), "replica-learning-lock-"))
after(() => rmSync(work, { recursive: true, force: true }))
let count = 0
function lockPath() {
  return path.join(work, `lock-${++count}`)
}

function age(file, milliseconds) {
  const then = new Date(Date.now() - milliseconds)
  utimesSync(file, then, then)
}

function injected(what) {
  return Object.assign(new Error(`Injected ${what} failure.`), { code: "EIO" })
}

describe("file lock", () => {
  it(
    "refuses a dangling lock link without following it or retrying forever",
    {
      skip: process.platform === "win32",
      timeout: 2_000,
    },
    async () => {
      const file = lockPath()
      symlinkSync(`${file}-missing`, file)
      const started = Date.now()
      await assert.rejects(
        createFileLock({ path: file, timeoutMs: 100 }).run(async () => assert.fail("entered work")),
        { code: "storage_corrupt" },
      )
      assert.ok(Date.now() - started < 1_000)
      assert.equal(lstatSync(file).isSymbolicLink(), true)
      assert.equal(existsSync(`${file}-missing`), false)
    },
  )

  it("does not reclaim an old ownership guard that may still be in use", async () => {
    const file = lockPath()
    writeFileSync(file, "")
    const marker = `${file}-break`
    mkdirSync(marker)
    age(marker, 120_000)
    await assert.rejects(
      createFileLock({ path: file, timeoutMs: 50, staleMs: 1 }).run(async () =>
        assert.fail("entered work"),
      ),
      { code: "conflict", message: /lock operation holds/ },
    )
    assert.equal(existsSync(marker), true)
  })

  it(
    "never enters work or removes a successor after its unfinished lock is reclaimed",
    {
      timeout: 5_000,
    },
    async (t) => {
      const probe = await open(import.meta.filename)
      await probe.close()
      const FileHandle = Object.getPrototypeOf(probe)
      const writeFile = FileHandle.writeFile
      for (const fails of [false, true]) {
        const file = lockPath()
        const paused = Promise.withResolvers()
        const resume = Promise.withResolvers()
        const entered = Promise.withResolvers()
        const finish = Promise.withResolvers()
        let pauseNext = true
        let firstEntered = false
        t.mock.method(FileHandle, "writeFile", async function (...args) {
          if (pauseNext) {
            pauseNext = false
            paused.resolve()
            await resume.promise
            if (fails) throw injected("write")
          }
          return writeFile.apply(this, args)
        })
        const first = createFileLock({ path: file, timeoutMs: 1_000, staleMs: 1 }).run(async () => {
          firstEntered = true
        })
        const refused = assert.rejects(first, { code: fails ? "EIO" : "conflict" })
        await paused.promise
        age(file, 120_000)
        const second = createFileLock({ path: file, timeoutMs: 1_000, staleMs: 1 }).run(
          async () => {
            entered.resolve()
            await finish.promise
          },
        )
        try {
          await entered.promise
          const successor = readFileSync(file, "utf8")
          resume.resolve()
          await refused
          assert.equal(firstEntered, false)
          assert.equal(readFileSync(file, "utf8"), successor)
        } finally {
          resume.resolve()
          finish.resolve()
          await Promise.allSettled([first, second])
        }
      }
    },
  )

  it("never breaks a lock whose process is still running, however old", async () => {
    const file = lockPath()
    writeFileSync(
      file,
      JSON.stringify({ token: "live", pid: process.pid, host: hostname(), at: 0 }),
    )
    age(file, 3_600_000)
    const lock = createFileLock({ path: file, timeoutMs: 100, staleMs: 1 })
    await assert.rejects(
      lock.run(async () => {}),
      { code: "conflict" },
    )
    assert.equal(JSON.parse(readFileSync(file, "utf8")).token, "live")
  })

  it("breaks a lock whose process has exited", async () => {
    const file = lockPath()
    writeFileSync(
      file,
      JSON.stringify({ token: "dead", pid: 2_147_483_646, host: hostname(), at: Date.now() }),
    )
    const lock = createFileLock({ path: file, timeoutMs: 1_000 })
    assert.equal(await lock.run(async () => "ran"), "ran")
  })

  it("waits for a holder that has not written its token yet", async () => {
    const file = lockPath()
    writeFileSync(file, "")
    const lock = createFileLock({ path: file, timeoutMs: 100, staleMs: 60_000 })
    await assert.rejects(
      lock.run(async () => {}),
      { code: "conflict" },
    )
    age(file, 120_000)
    assert.equal(await lock.run(async () => "ran"), "ran")
  })

  it("releases only its own lock, never a successor's", async () => {
    const file = lockPath()
    const lock = createFileLock({ path: file })
    await lock.run(async () => {
      writeFileSync(
        file,
        JSON.stringify({ token: "successor", pid: process.pid, host: hostname(), at: Date.now() }),
      )
    })
    assert.equal(JSON.parse(readFileSync(file, "utf8")).token, "successor")
  })

  it("removes its lock file when taking the lock fails after writing its token", async (t) => {
    const file = lockPath()
    const lock = createFileLock({ path: file, timeoutMs: 100 })
    // Closing the lock file fails once, after the token is written.
    const probe = await open(import.meta.filename)
    await probe.close()
    const FileHandle = Object.getPrototypeOf(probe)
    const writeFile = FileHandle.writeFile
    let failing = true
    t.mock.method(FileHandle, "writeFile", async function (...args) {
      await writeFile.apply(this, args)
      if (!failing) return
      failing = false
      const close = this.close
      this.close = async () => {
        await close()
        throw injected("close")
      }
    })
    await assert.rejects(
      lock.run(async () => "ran"),
      { code: "EIO" },
    )
    assert.equal(existsSync(file), false)
    assert.equal(await lock.run(async () => "ran"), "ran")
  })

  it(
    "removes a lock it could not release before it takes the lock again",
    { skip: process.platform === "win32" || process.getuid?.() === 0 },
    async () => {
      const directory = mkdtempSync(path.join(work, "release-"))
      const file = path.join(directory, "lock")
      const lock = createFileLock({ path: file, timeoutMs: 100 })
      // While the work runs, the directory stops accepting changes, so releasing fails.
      const result = await lock.run(async () => {
        chmodSync(directory, 0o500)
        return "ran"
      })
      chmodSync(directory, 0o700)
      assert.equal(result, "ran")
      assert.equal(existsSync(file), true)
      assert.equal(await lock.run(async () => "ran again"), "ran again")
      assert.equal(existsSync(file), false)
    },
  )

  it(
    "lets a new lock in this process remove a lock file whose token it could not write",
    { skip: process.platform === "win32" || process.getuid?.() === 0 },
    async (t) => {
      const directory = mkdtempSync(path.join(work, "token-"))
      const file = path.join(directory, "lock")
      // Writing the token stops part way, and the file cannot be removed either.
      const probe = await open(import.meta.filename)
      await probe.close()
      const FileHandle = Object.getPrototypeOf(probe)
      const writeFile = FileHandle.writeFile
      let failing = true
      t.mock.method(FileHandle, "writeFile", async function (...args) {
        if (!failing) return writeFile.apply(this, args)
        failing = false
        await writeFile.call(this, "{")
        chmodSync(directory, 0o500)
        throw injected("write")
      })
      await assert.rejects(
        createFileLock({ path: file }).run(async () => "ran"),
        { code: "EIO" },
      )
      chmodSync(directory, 0o700)
      assert.equal(readFileSync(file, "utf8"), "{")
      const fresh = createFileLock({ path: file, timeoutMs: 100 })
      assert.equal(await fresh.run(async () => "ran"), "ran")
      assert.equal(existsSync(file), false)
    },
  )

  it("lets one writer in at a time", async () => {
    const file = lockPath()
    const lock = createFileLock({ path: file, timeoutMs: 5_000 })
    let inside = 0
    let most = 0
    await Promise.all(
      Array.from({ length: 10 }, () =>
        lock.run(async () => {
          inside++
          most = Math.max(most, inside)
          await new Promise((resolve) => setTimeout(resolve, 5))
          inside--
        }),
      ),
    )
    assert.equal(most, 1)
  })
})
