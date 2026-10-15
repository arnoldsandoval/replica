import { randomBytes } from "node:crypto"
import { hostname } from "node:os"
import { lstat, mkdir, open, readFile, rmdir, unlink } from "node:fs/promises"
import { setTimeout as sleep } from "node:timers/promises"
import { LearningError } from "../errors.mjs"

/**
 * Lock files this process took and could not remove, by path, with the token and inode each had.
 * Every lock for that path in this process removes the file first, whichever lock left it.
 */
const leftovers = new Map()

/**
 * An exclusive lock file for the readers and writers sharing one directory.
 *
 * The holder writes a token, its process ID, and its host. Only the holder that wrote a token
 * removes the lock. On the same host, a lock is abandoned only when its process has exited,
 * however long the holder takes. A lock from another host, or one whose holder had not yet
 * written its token, is abandoned after staleMs. Processes breaking an abandoned lock take a
 * second marker first. Ownership confirmation and removal take that same marker, so a writer
 * whose unfinished lock was reclaimed never enters work or removes its successor's lock.
 * A marker is never reclaimed by age: its holder could be paused. If its process crashes,
 * operations time out until someone removes it after checking that the process has stopped.
 *
 * No other process breaks a lock whose process is alive, so a holder must not leave one behind.
 * If taking the lock fails after the file is created, the file is removed. If the file cannot
 * be removed, at that point or on release, the next call for that path from this process, by
 * any lock, removes it first, even when its token was only partly written.
 *
 * @param {{ path: string, timeoutMs?: number, staleMs?: number }} options
 */
export function createFileLock({ path, timeoutMs = 10_000, staleMs = 600_000 }) {
  const breaking = `${path}-break`
  const host = hostname()
  // Resolves when this process releases the lock, so callers waiting in this process try again
  // at once rather than at their next poll.
  let released = Promise.withResolvers()

  async function guarded(work) {
    const started = Date.now()
    for (;;) {
      try {
        await mkdir(breaking, { mode: 0o700 })
        break
      } catch (error) {
        const pendingRemoval = process.platform === "win32" && error.code === "EPERM"
        if (error.code !== "EEXIST" && !pendingRemoval) throw error
        if (Date.now() - started >= timeoutMs) {
          if (pendingRemoval) throw error
          throw new LearningError(
            "conflict",
            `Another lock operation holds ${breaking}. Remove that marker only after its process has stopped.`,
          )
        }
        await sleep(15)
      }
    }
    try {
      return await work()
    } finally {
      await rmdir(breaking)
    }
  }

  async function holder() {
    let text
    let info
    try {
      info = await lstat(path)
      if (!info.isFile() || info.nlink > 1)
        throw new LearningError(
          "storage_corrupt",
          `${path} is not a private regular lock file. Remove the invalid entry before trying again.`,
        )
      text = await readFile(path, "utf8")
    } catch (error) {
      if (error.code === "ENOENT") return null
      throw error
    }
    try {
      const value = JSON.parse(text)
      if (
        typeof value.token === "string" &&
        Number.isSafeInteger(value.pid) &&
        typeof value.host === "string"
      )
        return { ...value, modified: info.mtimeMs, ino: info.ino }
    } catch {
      // A holder that has created the file but not yet written its token.
    }
    return { token: null, modified: info.mtimeMs, ino: info.ino }
  }

  function abandoned(current) {
    if (current.token && current.host === host) return !alive(current.pid)
    return Date.now() - (current.token ? current.at : current.modified) > staleMs
  }

  async function breakIfAbandoned() {
    return guarded(async () => {
      const current = await holder()
      if (!current) return true
      if (!abandoned(current)) return false
      await unlink(path).catch((error) => {
        if (error.code !== "ENOENT") throw error
      })
      return true
    })
  }

  /** Only the owner may remove its file, including an unfinished token identified by its inode. */
  async function removeOwned({ token, ino }) {
    return guarded(async () => {
      const current = await holder()
      if (
        current &&
        (current.token === token ||
          (current.token === null && ino !== undefined && current.ino === ino))
      )
        await unlink(path).catch((error) => {
          if (error.code !== "ENOENT") throw error
        })
    })
  }

  /** Remove the lock file this process took and could not remove, if it is still that file. */
  async function removeLeftover() {
    const leftover = leftovers.get(path)
    // Claim it first, so no other lock in this process removes it and then a successor's lock.
    leftovers.delete(path)
    try {
      await removeOwned(leftover)
    } catch (error) {
      if (error.code === "ENOENT") return
      leftovers.set(path, leftover)
      throw error
    }
  }

  /** Remove the lock file if this call still holds it, or leave that to the next call. */
  async function release(owner) {
    try {
      await removeOwned(owner)
    } catch (error) {
      if (error.code !== "ENOENT") leftovers.set(path, owner)
    } finally {
      released.resolve()
      released = Promise.withResolvers()
    }
  }

  return {
    /**
     * Take the lock, run work, and release the lock only if this call still holds it. A failure
     * to release does not fail the call; the next call for this path from this process removes
     * the lock first.
     */
    async run(work) {
      const token = randomBytes(16).toString("hex")
      const owner = { token, ino: undefined }
      const started = Date.now()
      for (;;) {
        if (leftovers.has(path)) await removeLeftover()
        let handle
        try {
          handle = await open(path, "wx", 0o600)
        } catch (error) {
          // Windows can keep a removed name inaccessible until earlier handles have closed.
          if (process.platform === "win32" && error.code === "EPERM") {
            if (Date.now() - started >= timeoutMs) throw error
            await sleep(15)
            continue
          }
          if (error.code !== "EEXIST") throw error
          if (Date.now() - started >= timeoutMs) {
            const current = await holder()
            throw new LearningError(
              "conflict",
              `Another reader or writer holds ${path}${current?.pid ? ` (process ${current.pid} on ${current.host})` : ""}. If no replica-learning process is running, delete that file.`,
            )
          }
          if (await breakIfAbandoned()) continue
          await Promise.race([sleep(15 + Math.floor(Math.random() * 25)), released.promise])
          continue
        }
        try {
          owner.ino = (await handle.stat()).ino
          await handle.writeFile(JSON.stringify({ token, pid: process.pid, host, at: Date.now() }))
          await handle.close()
          await guarded(async () => {
            const current = await holder()
            if (current?.token !== token || current.ino !== owner.ino)
              throw new LearningError(
                "conflict",
                `Ownership of ${path} changed while taking the lock. Try again.`,
              )
          })
        } catch (error) {
          // Remove only this call's file: a paused writer may have lost it to a successor.
          // If removal fails, a later call retries it; the inode identifies an unfinished token.
          await handle.close().catch(() => {})
          await removeOwned(owner).catch(() => leftovers.set(path, owner))
          throw error
        }
        break
      }
      try {
        return await work()
      } finally {
        await release(owner)
      }
    },
  }
}

function alive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error.code === "EPERM"
  }
}
