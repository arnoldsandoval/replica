import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import assert from "node:assert/strict"
import { after, describe, it } from "node:test"
import { memoryProviderConformance } from "../conformance/index.mjs"
import { createInMemoryProvider } from "../src/providers/in-memory.mjs"
import { createJsonLinesMemoryProvider } from "../src/providers/json-lines.mjs"
import { createSqliteMemoryProvider } from "../src/providers/sqlite.mjs"
import { createMemoryProvider } from "./fixtures/json-file-provider.mjs"

const work = mkdtempSync(path.join(tmpdir(), "replica-learning-conformance-"))
const opened = []
after(async () => {
  for (const provider of opened) await provider.close()
  rmSync(work, { recursive: true, force: true })
})
let count = 0

it("declares every public conformance export for TypeScript consumers", async () => {
  const runtime = await import("../conformance/index.mjs")
  const source = readFileSync(new URL("../conformance/index.d.mts", import.meta.url), "utf8")
  const declared = [...source.matchAll(/^export declare (?:function|const) (\w+)/gm)]
    .map((match) => match[1])
    .sort()
  assert.deepEqual(declared, Object.keys(runtime).sort())
})

memoryProviderConformance({
  name: "in-memory provider",
  createProvider: () => createInMemoryProvider(),
})

memoryProviderConformance({
  name: "SQLite provider",
  createProvider: () => {
    const provider = createSqliteMemoryProvider({ directory: path.join(work, `sqlite-${++count}`) })
    opened.push(provider)
    return provider
  },
})

memoryProviderConformance({
  name: "JSON Lines provider",
  createProvider: () =>
    createJsonLinesMemoryProvider({ directory: path.join(work, `store-${++count}`) }),
})

// Written only from the contract, with no imports from this package.
memoryProviderConformance({
  name: "independent single-file provider",
  createProvider: () => createMemoryProvider({ dataDirectory: path.join(work, `file-${++count}`) }),
})

describe("independent single-file provider instances", () => {
  it("serializes writes from different instances that resolve to the same file", async () => {
    const dataDirectory = path.join(work, `shared-file-${++count}`)
    const first = createMemoryProvider({ dataDirectory })
    const second = createMemoryProvider({
      dataDirectory: path.relative(process.cwd(), dataDirectory),
    })
    const scope = { repository: "acme/prototypes" }
    const records = Array.from({ length: 20 }, (_, index) => ({
      id: `ev_concurrent${String(index).padStart(8, "0")}`,
      digest: `sha256:${index}`,
      scope,
    }))
    await Promise.all(
      records.map((record, index) =>
        [first, second][index % 2].appendRecords("events", [record], {
          audit: [{ ...record, id: `audit_${record.id}` }],
        }),
      ),
    )
    assert.deepEqual(
      (await second.readRecords("events", { scope })).map((record) => record.id).sort(),
      records.map((record) => record.id).sort(),
    )
    assert.equal((await first.readRecords("audit", { scope })).length, records.length)
  })

  it("lets only one instance store a competing memory version", async () => {
    const dataDirectory = path.join(work, `shared-memory-${++count}`)
    const providers = [
      createMemoryProvider({ dataDirectory }),
      createMemoryProvider({ dataDirectory }),
    ]
    const scope = { repository: "acme/prototypes" }
    const results = await Promise.allSettled(
      providers.map((provider, index) =>
        provider.appendMemoryVersion(
          {
            id: "mem_concurrentversion1",
            version: 1,
            digest: `sha256:${index}`,
            scope,
          },
          { expectedPreviousDigest: null },
        ),
      ),
    )
    assert.equal(results.filter((result) => result.status === "fulfilled").length, 1)
    assert.equal(results.find((result) => result.status === "rejected").reason.code, "conflict")
    assert.equal((await providers[0].readMemoryVersions({ scope })).length, 1)
  })
})
