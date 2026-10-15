import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { describe, it } from "node:test"
import { isDeepStrictEqual } from "node:util"
import {
  MAX_DEPTH,
  canonicalJson,
  digestOf,
  jsonLines,
  parseJson,
  portabilityProblems,
} from "../src/canonical-json.mjs"
import {
  isTimestamp,
  normalizeTimestamp,
  parseTimeOption,
  timestampMilliseconds,
} from "../src/time.mjs"
import { sealEvent, sealMemory } from "../src/records.mjs"
import { quoteDiagnostic } from "../src/errors.mjs"
import { RECORD_KINDS, validateRecord } from "../src/validate.mjs"

const contracts = new URL("../contracts/v1/", import.meta.url)
function readJson(url) {
  return JSON.parse(readFileSync(url, "utf8"))
}

function kindOf(file) {
  return file.split(".")[0].replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())
}

describe("v1 contracts", () => {
  const examples = readdirSync(new URL("examples/", contracts)).filter((file) =>
    file.endsWith(".json"),
  )
  const invalid = readdirSync(new URL("invalid/", contracts)).filter((file) =>
    file.endsWith(".json"),
  )

  it("has a valid example for every record kind", () => {
    assert.deepEqual([...new Set(examples.map(kindOf))].sort(), [...RECORD_KINDS].sort())
  })

  for (const file of examples)
    it(`accepts examples/${file}`, () => {
      assert.deepEqual(
        validateRecord(kindOf(file), readJson(new URL(`examples/${file}`, contracts))),
        { valid: true, errors: [] },
      )
    })

  for (const file of invalid)
    it(`rejects invalid/${file} for its stated reason`, () => {
      const { kind, reason, expect, record } = readJson(new URL(`invalid/${file}`, contracts))
      assert.ok(reason, "each invalid fixture says why it must fail")
      const result = validateRecord(kind, record)
      assert.equal(result.valid, false)
      assert.ok(
        result.errors.some((error) => error.includes(expect)),
        `${file}: expected an error containing ${JSON.stringify(expect)}, got ${JSON.stringify(result.errors)}`,
      )
    })

  it("refuses unknown record kinds, including inherited object properties", () => {
    for (const kind of ["unknown", "toString", "constructor", "valueOf", "__proto__"])
      assert.throws(() => validateRecord(kind, {}), { code: "invalid_input" }, kind)
  })

  it("escapes untrusted additional-property names and portability paths in diagnostics", () => {
    const key = "\u001b[2J\n\u009b2J\u0085\u2028\u2029\u202eForged output"
    const event = readJson(new URL("examples/event.annotation.example.json", contracts))
    event.payload.theme[key] = true
    const result = validateRecord("event", event, { sealed: false })
    assert.equal(result.valid, false)
    assert.ok(result.errors.some((error) => error.includes("\\u001b[2J\\n\\u009b2J\\u0085")))
    assert.doesNotMatch(result.errors.join("; "), /[\p{Cc}\p{Cf}\u2028\u2029]/u)
    const paths = portabilityProblems({ [key]: { value: NaN } })
    assert.ok(paths.some((error) => error.includes("\\u001b[2J\\n\\u009b2J\\u0085")))
    assert.doesNotMatch(paths.join("; "), /[\p{Cc}\p{Cf}\u2028\u2029]/u)
    const encoded = quoteDiagnostic(`${key}\u{E0041}`)
    assert.doesNotMatch(encoded, /[\p{Cc}\p{Cf}\u2028\u2029]/u)
    assert.equal(JSON.parse(encoded), `${key}\u{E0041}`)
  })

  it("checks the payload and event digests of exported timelines", () => {
    for (const change of [
      (event) => {
        event.payload.body = "Altered comment."
      },
      (event) => {
        event.actor.id = "github:another-reviewer"
      },
    ]) {
      const episode = readJson(new URL("examples/episode.timeline.example.json", contracts))
      change(episode.timeline[0])
      const result = validateRecord("episode", episode)
      assert.equal(result.valid, false)
      assert.ok(result.errors.some((error) => error.includes("/timeline/0")))
      assert.equal(validateRecord("episode", episode, { sealed: false }).valid, true)
    }
  })

  it("returns validation errors for the largest corrupted timeline instead of throwing", () => {
    const episode = readJson(new URL("examples/episode.example.json", contracts))
    const event = readJson(new URL("examples/event.human-comment.example.json", contracts))
    event.payloadDigest = `sha256:${"0".repeat(64)}`
    event.digest = `sha256:${"0".repeat(64)}`
    episode.timeline = Array(100_000).fill(event)
    const result = validateRecord("episode", episode)
    assert.equal(result.valid, false)
    assert.equal(result.errors.length, 200_000)
    assert.match(result.errors[0], /^\/timeline\/0:/)
    assert.match(result.errors.at(-1), /^\/timeline\/99999:/)
  })

  it("checks target links only for labels and retractions, including in timelines", () => {
    const base = readJson(new URL("examples/event.human-comment.example.json", contracts))
    const generic = sealEvent({
      ...base,
      type: "x-acme.checkout_step",
      payload: { target: { eventId: "ev_unrelated1" } },
    })
    assert.deepEqual(validateRecord("event", generic), { valid: true, errors: [] })
    for (const name of ["annotation", "no-annotation", "retraction"]) {
      const event = readJson(new URL(`examples/event.${name}.example.json`, contracts))
      event.parentEventId = "ev_unrelated1"
      const sealed = sealEvent(event)
      assert.match(
        validateRecord("event", sealed).errors.join("; "),
        /parentEventId must name/,
        name,
      )
      const episode = readJson(new URL("examples/episode.example.json", contracts))
      episode.timeline = [sealed]
      assert.match(
        validateRecord("episode", episode).errors.join("; "),
        /\/timeline\/0.*parentEventId must name/,
        name,
      )
    }
  })

  it("checks calendar validity only where the schema declares a timestamp", () => {
    const impossible = "2026-02-30T00:00:00.000000Z"
    const comment = readJson(new URL("examples/event.human-comment.example.json", contracts))
    comment.payload.body = impossible
    assert.deepEqual(validateRecord("event", sealEvent(comment)), { valid: true, errors: [] })
    const generic = sealEvent({
      ...comment,
      type: "x-acme.checkout_step",
      payload: { at: impossible, nested: { createdAt: impossible }, text: [impossible] },
    })
    assert.deepEqual(validateRecord("event", generic), { valid: true, errors: [] })
    const memory = readJson(new URL("examples/memory-record.proposed.example.json", contracts))
    memory.content = impossible
    memory.proposal.rationale.recurrence = impossible
    assert.deepEqual(validateRecord("memoryRecord", sealMemory(memory)), {
      valid: true,
      errors: [],
    })
    for (const mutate of [
      (event) => {
        event.at = impossible
      },
      (event) => {
        event.payload.createdAt = impossible
      },
      (event) => {
        event.payload.editedAt = impossible
      },
    ]) {
      const event = structuredClone(comment)
      mutate(event)
      assert.equal(validateRecord("event", sealEvent(event)).valid, false)
      const episode = readJson(new URL("examples/episode.example.json", contracts))
      episode.timeline = [sealEvent(event)]
      assert.equal(validateRecord("episode", episode).valid, false)
    }
    const collection = readJson(new URL("examples/collection.example.json", contracts))
    collection.filters.from = impossible
    assert.equal(validateRecord("collection", collection, { sealed: false }).valid, false)
    const reference = readJson(new URL("examples/evidence-ref.example.json", contracts))
    reference.observedAt = impossible
    assert.equal(validateRecord("evidenceRef", reference).valid, false)
  })

  it("gives every schema a versioned $id and keeps cross-file references inside v1", () => {
    for (const file of readdirSync(contracts).filter((name) => name.endsWith(".schema.json"))) {
      const schema = readJson(new URL(file, contracts))
      assert.equal(schema.$id, `https://github.com/github/replica/learning/v1/${file}`)
      const refs = JSON.stringify(schema).match(/"\$ref":"([^"#]+)/g) ?? []
      for (const ref of refs) assert.match(ref, /"\$ref":"[a-z-]+\.schema\.json/)
    }
  })
})

describe("canonical JSON and digests", () => {
  const vectors = readJson(new URL("vectors/canonical-json.json", contracts))
  function accept(text) {
    try {
      return canonicalJson(parseJson(text))
    } catch {
      return "refused"
    }
  }

  it("writes every case in RFC 8785 form", () => {
    assert.deepEqual(
      vectors.cases
        .filter(({ value, canonical }) => canonicalJson(value) !== canonical)
        .map(({ name }) => name),
      [],
    )
  })

  it("refuses values RFC 8785 cannot write", () => {
    for (const { name, value } of vectors.rejects)
      assert.throws(() => canonicalJson(value), /RFC 8785 has no form/, name)
  })

  it("validates portability as every reader must", () => {
    for (const { name, value } of vectors.validation_rejects)
      assert.ok(portabilityProblems(value).length, name)
    for (const { name, value } of vectors.validation_accepts)
      assert.deepEqual(portabilityProblems(value), [], name)
  })

  it("refuses sparse and undefined array items before calculating a digest", () => {
    const sparse = [1, 2, 3]
    delete sparse[1]
    for (const items of [Array(1), sparse, [undefined]]) {
      const value = { nested: { items } }
      assert.ok(portabilityProblems(value).length)
      assert.throws(() => canonicalJson(value), /RFC 8785 has no form/)
      assert.throws(() => digestOf(value), /RFC 8785 has no form/)
      const event = readJson(new URL("examples/event.human-comment.example.json", contracts))
      event.type = "x-acme.checkout_step"
      event.payload = value
      assert.equal(validateRecord("event", event, { sealed: false }).valid, false)
      assert.throws(() => sealEvent(event), /RFC 8785 has no form/)
    }
    const value = { items: [null, false, 0, "", { omitted: undefined }] }
    assert.deepEqual(portabilityProblems(value), [])
    assert.equal(canonicalJson(value), canonicalJson(JSON.parse(JSON.stringify(value))))
  })

  it("refuses non-JSON objects and serialization hooks without invoking them", () => {
    let invoked = 0
    function serialize() {
      invoked++
      return "Different stored content."
    }
    const hiddenHook = Object.defineProperty({}, "toJSON", { value: serialize })
    const hookedArray = Object.assign(["original"], { toJSON: serialize })
    const hiddenArrayHook = Object.defineProperty(["original"], "toJSON", { value: serialize })
    const accessor = Object.defineProperty({}, "observed", { enumerable: true, get: serialize })
    const arrayAccessor = Object.defineProperty([1], "0", { get: serialize })
    const cases = [
      new Date("2026-10-01T00:00:00Z"),
      new Map([["observed", true]]),
      new Set([1]),
      new Uint8Array([1]),
      /observed/,
      Object(1),
      Object.create({ inherited: "not JSON" }),
      { toJSON: serialize },
      hiddenHook,
      hookedArray,
      hiddenArrayHook,
      Object.defineProperty({}, "observed", { value: true }),
      Object.defineProperty([1], "0", { value: 1, enumerable: false }),
      accessor,
      arrayAccessor,
      { callback: serialize },
      { value: Symbol("not JSON") },
      { value: 1n },
    ]
    for (const value of cases) {
      const payload = { nested: value }
      assert.ok(portabilityProblems(payload).length)
      assert.throws(() => canonicalJson(payload), /RFC 8785 has no form/)
      assert.throws(() => digestOf(payload), /RFC 8785 has no form/)
      const event = readJson(new URL("examples/event.human-comment.example.json", contracts))
      event.type = "x-acme.checkout_step"
      event.payload = payload
      assert.equal(validateRecord("event", event, { sealed: false }).valid, false)
    }
    assert.equal(invoked, 0)
    for (const value of [
      { toJSON: "an ordinary JSON property", observed: "2026-10-01T00:00:00Z" },
      Object.assign(Object.create(null), { observed: [true, null, 1] }),
    ]) {
      assert.deepEqual(portabilityProblems(value), [])
      assert.equal(canonicalJson(value), canonicalJson(JSON.parse(JSON.stringify(value))))
    }
  })

  it("reads raw text and JSON Lines the same way as other implementations", () => {
    function differ(cases, read) {
      return cases
        .filter(({ text, canonical = "refused" }) => !isDeepStrictEqual(read(text), canonical))
        .map(({ name }) => name)
    }
    function acceptLines(text) {
      const outcomes = jsonLines(text).map(({ text: line }) => accept(line))
      return outcomes.includes("refused") ? "refused" : outcomes
    }
    assert.deepEqual(differ(vectors.raw_cases, accept), [])
    assert.deepEqual(differ(vectors.jsonl_cases, acceptLines), [])
    assert.equal(vectors.max_depth, MAX_DEPTH)
    function nested(depth) {
      return `${"[".repeat(depth)}0${"]".repeat(depth)}`
    }
    assert.deepEqual(
      [MAX_DEPTH, MAX_DEPTH + 1].map((depth) => accept(nested(depth))),
      [nested(MAX_DEPTH), "refused"],
    )
  })

  it("prefixes digests and leaves undefined members out, as JSON.stringify does", () => {
    assert.equal(digestOf({ b: 1, a: undefined }), digestOf({ b: 1 }))
    assert.match(digestOf({ a: 1 }), /^sha256:[0-9a-f]{64}$/)
    assert.throws(() => canonicalJson({ a: () => {} }), /no form for a function/)
  })
})

describe("timestamps", () => {
  it("preserves years below 100 in normalization and millisecond conversion", () => {
    for (const year of ["0000", "0001", "0099"]) {
      const value = `${year}-10-02T14:00:00.123456Z`
      assert.equal(isTimestamp(value), true)
      assert.equal(normalizeTimestamp(value), value)
      assert.equal(normalizeTimestamp(`${year}-10-02T16:00:00.123456+02:00`), value)
      assert.equal(timestampMilliseconds(value), Date.parse(value))
    }
    assert.equal(normalizeTimestamp("0000-02-29T00:00:00Z"), "0000-02-29T00:00:00.000000Z")
    assert.throws(() => normalizeTimestamp("0099-02-29T00:00:00Z"))
    assert.throws(() => timestampMilliseconds("0099-02-29T00:00:00.000000Z"))
  })

  it("refuses offsets that move outside the four-digit UTC year range", () => {
    for (const value of ["0000-01-01T00:00:00+01:00", "9999-12-31T23:30:00-01:00"])
      assert.throws(() => normalizeTimestamp(value))
  })

  it("normalizes offsets and precision so text order is time order", () => {
    assert.equal(normalizeTimestamp("2026-10-02T16:00:00+02:00"), "2026-10-02T14:00:00.000000Z")
    assert.equal(normalizeTimestamp("2026-10-02T14:00:00.1234567Z"), "2026-10-02T14:00:00.123456Z")
    assert.equal(normalizeTimestamp("2026-10-02T23:30:00-01:00"), "2026-10-03T00:30:00.000000Z")
    assert.throws(() => normalizeTimestamp("2026-02-30T00:00:00Z"))
    assert.throws(() => normalizeTimestamp("2026-10-02 14:00:00Z"))
    assert.equal(isTimestamp("2026-10-02T14:00:00.000000Z"), true)
    assert.equal(isTimestamp("2026-10-02T24:00:00.000000Z"), false)
  })

  it("reads relative times against the clock", () => {
    const now = Date.parse("2026-10-09T12:00:00Z")
    assert.equal(parseTimeOption("7d", now), "2026-10-02T12:00:00.000000Z")
    assert.equal(parseTimeOption("now", now), "2026-10-09T12:00:00.000000Z")
    assert.equal(parseTimeOption("30m", now), "2026-10-09T11:30:00.000000Z")
  })
})
