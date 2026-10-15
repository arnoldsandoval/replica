import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdir, rm } from "node:fs/promises"
import path from "node:path"
import { describe, it } from "node:test"

import { readRepositoryName } from "./index.mjs"

describe("readRepositoryName()", () => {
  it("recognizes GitHub HTTPS, scp-like, and URL-form SSH origins", async () => {
    const workspace = path.join(process.cwd(), "storage/replica-extension-tests", randomUUID())
    await mkdir(workspace, { recursive: true })
    try {
      execFileSync("git", ["init", "-q", workspace])
      execFileSync("git", [
        "-C",
        workspace,
        "remote",
        "add",
        "origin",
        "https://github.com/GitHub/Replica.git",
      ])
      for (const url of [
        "https://github.com/GitHub/Replica.git",
        "git@github.com:GitHub/Replica.git",
        "ssh://git@github.com/GitHub/Replica.git",
      ]) {
        execFileSync("git", ["-C", workspace, "remote", "set-url", "origin", url])
        assert.deepEqual(await readRepositoryName(workspace), {
          repository: "github/replica",
          legacyRepository: "GitHub/Replica",
          error: null,
        })
      }
    } finally {
      await rm(workspace, { recursive: true, force: true })
    }
  })

  it("does not accept SSH origins from another host, user, or GitHub-like hostname", async () => {
    const workspace = path.join(process.cwd(), "storage/replica-extension-tests", randomUUID())
    await mkdir(workspace, { recursive: true })
    try {
      execFileSync("git", ["init", "-q", workspace])
      execFileSync("git", [
        "-C",
        workspace,
        "remote",
        "add",
        "origin",
        "ssh://git@evil.example/GitHub/Replica.git",
      ])
      for (const url of [
        "ssh://git@evil.example/GitHub/Replica.git",
        "ssh://git@github.com.evil.example/GitHub/Replica.git",
        "ssh://root@github.com/GitHub/Replica.git",
        "ssh://git@github.com/GitHub/Replica.git?unexpected=1",
      ]) {
        execFileSync("git", ["-C", workspace, "remote", "set-url", "origin", url])
        assert.deepEqual(await readRepositoryName(workspace), {
          repository: null,
          error: "The origin remote is not a GitHub repository.",
        })
      }
    } finally {
      await rm(workspace, { recursive: true, force: true })
    }
  })
})
