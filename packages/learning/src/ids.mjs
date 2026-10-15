import { createHash, randomBytes } from "node:crypto"
import { canonicalJson } from "./canonical-json.mjs"

/** A random record ID such as grant_3f2a... with 96 random bits. */
export function randomId(prefix) {
  return `${prefix}_${randomBytes(12).toString("hex")}`
}

/** A record ID derived from a value, so importing or proposing the same thing twice is a no-op. */
export function derivedId(prefix, value) {
  return `${prefix}_${createHash("sha256").update(canonicalJson(value), "utf8").digest("hex").slice(0, 24)}`
}
