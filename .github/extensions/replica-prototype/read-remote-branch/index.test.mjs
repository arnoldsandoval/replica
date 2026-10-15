import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { readRemoteBranch } from "./index.mjs"

const target = {
  repository: "github/prototype",
  branch: "prototype/new",
  commitSha: "a".repeat(40),
  repositoryPath: "/test",
}
function ref(branch, sha = "a".repeat(40)) {
  return {
    ref: `refs/heads/${branch}`,
    object: { type: "commit", sha },
  }
}

describe("readRemoteBranch()", () => {
  it("queries the exact current branch in the verified origin, never an inherited upstream", async () => {
    const result = await readRemoteBranch(
      { ...target, upstream: "origin/old" },
      async (command, args) => {
        assert.equal(command, "gh")
        assert.deepEqual(args, [
          "api",
          "--hostname",
          "github.com",
          "repos/github/prototype/git/matching-refs/heads/prototype%2Fnew",
        ])
        return { ok: true, stdout: JSON.stringify([ref("prototype/new/child"), ref("old")]) }
      },
    )
    assert.equal(result.state, "absent")
    assert.equal(result.branch, target.branch)
  })
  it("distinguishes absent, matching and different remote commits", async () => {
    for (const refs of [[], [ref(target.branch)], [ref(target.branch, "b".repeat(40))]]) {
      const result = await readRemoteBranch(target, async () => ({
        ok: true,
        stdout: JSON.stringify(refs),
      }))
      assert.equal(result.state, refs.length ? "present" : "absent")
      assert.equal(result.remoteSha, refs[0]?.object.sha || null)
    }
  })
  it("never treats authentication, network, not-found or malformed results as absence", async () => {
    for (const response of [
      { ok: false, error: "HTTP 404" },
      { ok: false, error: "HTTP 403" },
      { ok: false, error: "Network unavailable" },
      { ok: true, stdout: "invalid" },
      { ok: true, stdout: "{}" },
      { ok: true, stdout: JSON.stringify([{ ref: "refs/heads/prototype/new" }]) },
    ]) {
      const result = await readRemoteBranch(target, async () => response)
      assert.equal(result.state, "unknown")
      assert.ok(result.error)
    }
  })
  it("does not query remote for detached HEAD, missing origin or missing commit", async () => {
    async function unexpected() {
      throw new Error("Must not query")
    }
    assert.equal(
      (await readRemoteBranch({ ...target, branch: null }, unexpected)).state,
      "detached",
    )
    assert.equal(
      (await readRemoteBranch({ ...target, repository: null }, unexpected)).state,
      "unknown",
    )
    assert.equal(
      (await readRemoteBranch({ ...target, commitSha: null }, unexpected)).state,
      "unknown",
    )
  })
})
