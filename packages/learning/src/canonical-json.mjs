import { createHash } from "node:crypto"
import { quoteDiagnostic } from "./errors.mjs"

/** A UTF-16 surrogate without its pair. It is not Unicode, so RFC 8785 cannot write it. */
export const LONE_SURROGATE = /\p{Cs}/u

/** The most arrays and objects a contract document may nest. */
export const MAX_DEPTH = 64

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

/**
 * Decode bytes as strict UTF-8. A byte order mark is kept, so JSON parsing refuses it.
 *
 * @param {Uint8Array} bytes
 * @param {string} label
 */
export function decodeUtf8(bytes, label = "input") {
  try {
    return UTF8.decode(bytes)
  } catch (error) {
    throw new Error(`${label} is not valid UTF-8`, { cause: error })
  }
}

/**
 * Values that other languages would not read the same way, each with its path. I-JSON
 * (RFC 7493) rules out non-finite numbers, whole numbers beyond 2^53 - 1, and lone
 * surrogates. Names with a backslash are refused because JSON.parse in Node 24 can misread
 * an escaped name (nodejs/node#63785). Nesting stops at MAX_DEPTH so no reader recurses
 * without bound.
 *
 * @param {unknown} value
 * @param {string} path
 * @param {number} depth
 * @returns {string[]}
 */
export function portabilityProblems(value, path = "", depth = 0) {
  const at = path || "(root)"
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return [`${at} should be a finite number`]
    return Number.isSafeInteger(value) || !Number.isInteger(value)
      ? []
      : [`${at} should be between -(2^53 - 1) and 2^53 - 1; write larger whole numbers as strings`]
  }
  if (typeof value === "string")
    return LONE_SURROGATE.test(value) ? [`${at} should not contain a lone surrogate`] : []
  if (["function", "symbol", "bigint"].includes(typeof value))
    return [`${at} should not be a ${typeof value}`]
  if (value === null || typeof value !== "object") return []
  const problem = objectProblem(value)
  if (problem) return [`${at} ${problem}`]
  if (depth >= MAX_DEPTH) return [`${at} should not nest more than ${MAX_DEPTH} levels deep`]
  if (Array.isArray(value))
    return Array.from({ length: value.length }, (_, index) =>
      !Object.hasOwn(value, index) || value[index] === undefined
        ? [`${path}[${index}] should not be an empty or undefined array item`]
        : portabilityProblems(value[index], `${path}[${index}]`, depth + 1),
    ).flat()
  return Object.entries(value).flatMap(([key, item]) => {
    const lone = LONE_SURROGATE.test(key)
    const child = /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key)
      ? `${path}.${key}`
      : `${path}[${quoteDiagnostic(key)}]`
    return [
      ...(lone ? [`${child} should not have a lone surrogate in its name`] : []),
      ...(key.includes("\\")
        ? [`${child} should not have a backslash in its name (nodejs/node#63785)`]
        : []),
      ...portabilityProblems(item, child, depth + 1),
    ]
  })
}

/** Reject objects whose property access or JSON serialization can change their contents. */
function objectProblem(value) {
  const prototype = Object.getPrototypeOf(value)
  if (
    Array.isArray(value)
      ? prototype !== Array.prototype
      : prototype !== Object.prototype && prototype !== null
  )
    return "should be a plain JSON object or array"
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key === "symbol") return "should not have symbol property names"
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!Object.hasOwn(descriptor, "value")) return "should not have accessor properties"
    if (!descriptor.enumerable && !(Array.isArray(value) && key === "length"))
      return "should not have non-enumerable data properties"
  }
  for (let current = value; current !== null; current = Object.getPrototypeOf(current)) {
    const descriptor = Object.getOwnPropertyDescriptor(current, "toJSON")
    if (!descriptor) continue
    if (!Object.hasOwn(descriptor, "value") || typeof descriptor.value === "function")
      return "should not have a custom toJSON serializer"
    break
  }
  return null
}

/**
 * The JSON Canonicalization Scheme of RFC 8785: object names sorted by UTF-16 code units, no
 * whitespace, and numbers and strings written as JSON.stringify writes them. Object members
 * whose value is undefined are left out, as JSON.stringify leaves them out.
 *
 * @param {unknown} value
 * @returns {string}
 */
export function canonicalJson(value) {
  if (value !== null && typeof value === "object") {
    const problem = objectProblem(value)
    if (problem) throw new Error(`RFC 8785 has no form for this object: ${problem}`)
  }
  if (Array.isArray(value))
    return `[${Array.from({ length: value.length }, (_, index) => {
      if (!Object.hasOwn(value, index))
        throw new Error("RFC 8785 has no form for an empty array item")
      return canonicalJson(value[index])
    }).join(",")}]`
  if (value !== null && typeof value === "object") {
    const fields = Object.keys(value)
      .filter((key) => value[key] !== undefined)
      .sort()
      .map((key) => `${canonicalJson(key)}:${canonicalJson(value[key])}`)
    return `{${fields.join(",")}}`
  }
  if (typeof value === "number" && !Number.isFinite(value))
    throw new Error("RFC 8785 has no form for a non-finite number")
  if (typeof value === "string" && LONE_SURROGATE.test(value))
    throw new Error("RFC 8785 has no form for a lone surrogate")
  if (value === null || ["string", "number", "boolean"].includes(typeof value))
    return JSON.stringify(value)
  throw new Error(`RFC 8785 has no form for a ${typeof value}`)
}

/**
 * The digest every v1 contract uses: sha256: and the hex SHA-256 of the canonical JSON.
 *
 * @param {unknown} value
 */
export function digestOf(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value), "utf8").digest("hex")}`
}

/**
 * Parse JSON text and refuse values other languages would read differently, including an
 * object that repeats a member name, which JSON.parse silently resolves to the last value
 * (I-JSON, RFC 7493, section 2.3).
 *
 * @param {string} text
 * @param {string} label
 */
export function parseJson(text, label = "input") {
  let value
  try {
    value = JSON.parse(text)
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`, { cause: error })
  }
  const repeated = repeatedName(text)
  if (repeated !== null)
    throw new Error(`${label} repeats the member name ${JSON.stringify(repeated)} in one object`)
  const problems = portabilityProblems(value)
  if (problems.length)
    throw new Error(`${label} is not portable JSON: ${problems.slice(0, 5).join("; ")}`)
  return value
}

/**
 * The first member name that one object of valid JSON text repeats, or null. Names are
 * compared after decoding escapes, so "\u0061" and "a" are the same name.
 *
 * @param {string} text JSON that JSON.parse already accepted
 */
export function repeatedName(text) {
  const stack = []
  let expectName = false
  for (let index = 0; index < text.length; index++) {
    const character = text[index]
    if (character === '"') {
      let end = index + 1
      while (text[end] !== '"') end += text[end] === "\\" ? 2 : 1
      if (expectName) {
        const name = JSON.parse(text.slice(index, end + 1))
        const names = stack.at(-1)
        if (names.has(name)) return name
        names.add(name)
        expectName = false
      }
      index = end
    } else if (character === "{") {
      stack.push(new Set())
      expectName = true
    } else if (character === "[") {
      stack.push(null)
    } else if (character === "}" || character === "]") {
      stack.pop()
    } else if (character === ",") {
      expectName = stack.at(-1) instanceof Set
    }
  }
  return null
}

/**
 * The non-blank lines of JSON Lines text with their line numbers. Lines end at \n only, and
 * a blank line holds only JSON whitespace.
 *
 * @param {string} text
 * @returns {Array<{ line: number, text: string }>}
 */
export function jsonLines(text) {
  return text
    .split("\n")
    .map((line, index) => ({ line: index + 1, text: line }))
    .filter(({ text: line }) => !/^[ \t\r]*$/.test(line))
}
