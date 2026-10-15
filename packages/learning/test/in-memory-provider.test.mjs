import assert from "node:assert/strict"
import { describe, it } from "node:test"
import { createInMemoryProvider } from "../src/providers/in-memory.mjs"

describe("in-memory provider atomic writes", () => {
  it("stores a batch larger than the JavaScript argument limit with all its audit entries", async () => {
    const provider = createInMemoryProvider()
    const scope = { repository: "acme/prototypes" }
    const episode = { id: "ep_largebatch1", digest: "sha256:episode", scope }
    const events = Array.from({ length: 180_000 }, (_, index) => ({
      id: `ev_${String(index).padStart(8, "0")}`,
      digest: `sha256:${index}`,
      scope,
      episodeId: episode.id,
    }))
    const audit = [{ id: "audit_largebatch1", digest: "sha256:audit", scope }]
    assert.deepEqual(await provider.appendBatch({ episodes: [episode], events }, { audit }), {
      episodes: { appended: 1, existing: 0 },
      events: { appended: events.length, existing: 0 },
    })
    assert.deepEqual(await provider.readRecords("episodes", { scope }), [episode])
    assert.deepEqual(await provider.readRecords("events", { scope }), events)
    assert.deepEqual(await provider.readRecords("audit", { scope }), audit)
  })

  it("stores a memory version with an audit list larger than the JavaScript argument limit", async () => {
    const provider = createInMemoryProvider()
    const scope = { repository: "acme/prototypes" }
    const version = { id: "mem_largeaudit1", version: 1, digest: "sha256:memory", scope }
    const audit = Array.from({ length: 180_000 }, (_, index) => ({
      id: `audit_${String(index).padStart(8, "0")}`,
      digest: `sha256:${index}`,
      scope,
    }))
    await provider.appendMemoryVersion(version, { expectedPreviousDigest: null, audit })
    assert.deepEqual(await provider.readMemoryVersions({ scope }), [version])
    assert.deepEqual(await provider.readRecords("audit", { scope }), audit)
  })

  it("clones every stream and audit entry before storing any part of a write", async () => {
    const provider = createInMemoryProvider()
    const scope = { repository: "acme/prototypes" }
    const episode = { id: "ep_clonefailure1", digest: "sha256:episode", scope }
    const invalid = { id: "ev_clonefailure1", digest: "sha256:event", scope, callback: () => {} }
    const audit = { id: "audit_clonefailure1", digest: "sha256:audit", scope }
    await assert.rejects(
      provider.appendBatch({ episodes: [episode], events: [invalid] }, { audit: [audit] }),
      { name: "DataCloneError" },
    )
    for (const stream of ["episodes", "events", "audit"])
      assert.deepEqual(await provider.readRecords(stream, { scope }), [])
    const version = { id: "mem_clonefailure1", version: 1, digest: "sha256:memory", scope }
    await assert.rejects(
      provider.appendMemoryVersion(version, {
        expectedPreviousDigest: null,
        audit: [{ ...audit, callback: () => {} }],
      }),
      { name: "DataCloneError" },
    )
    assert.deepEqual(await provider.readMemoryVersions({ scope }), [])
    assert.deepEqual(await provider.readRecords("audit", { scope }), [])
  })
})
