import assert from "node:assert/strict"
import {
  lstatSync,
  mkdtempSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { after, describe, it } from "node:test"
import { assertOwnPath, assertSameFile } from "../src/providers/files.mjs"

const work = mkdtempSync(path.join(tmpdir(), "replica-learning-files-"))
after(() => rmSync(work, { recursive: true, force: true }))

describe("assertOwnPath()", () => {
  it("accepts a file removed after it was found, as SQLite removes its log on close", () => {
    const file = path.join(work, "learning.sqlite-wal")
    writeFileSync(file, "", { mode: 0o600 })
    const info = lstatSync(file)
    rmSync(file)
    assert.doesNotThrow(() => assertOwnPath(work, file, info))
  })
})

describe("assertSameFile()", () => {
  it("refuses a path that no longer names the file that was checked", () => {
    const file = path.join(work, "learning.sqlite")
    writeFileSync(file, "", { mode: 0o600 })
    const checked = statSync(file)
    assert.doesNotThrow(() => assertSameFile(work, file, checked))

    const other = path.join(work, "other.sqlite")
    writeFileSync(other, "", { mode: 0o600 })
    renameSync(other, file)
    assert.throws(() => assertSameFile(work, file, checked), {
      code: "storage_corrupt",
      message: /was replaced after it was checked/,
    })

    rmSync(file)
    symlinkSync(path.join(work, "elsewhere.sqlite"), file)
    assert.throws(() => assertSameFile(work, file, checked), {
      code: "storage_corrupt",
      message: /is a symbolic link/,
    })
  })
})
