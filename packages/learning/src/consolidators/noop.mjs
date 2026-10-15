import { PRODUCER } from "../records.mjs"

/**
 * Proposes nothing. Use it to turn consolidation off while keeping capture and recall.
 *
 * A consolidator has a manifest, { id, version, description }, and consolidate(request,
 * view). It reads a frozen view of the evidence the request's purpose may use and returns
 * { proposals, diagnostics }. It cannot write: the learning store validates each proposal,
 * stores it as proposed, and only a person can accept it.
 */
export function createNoopConsolidator() {
  return {
    manifest: { id: "none", version: PRODUCER.version, description: "Proposes nothing." },
    async consolidate() {
      return {
        proposals: [],
        diagnostics: [{ code: "disabled", message: "Consolidation is turned off." }],
      }
    },
  }
}
