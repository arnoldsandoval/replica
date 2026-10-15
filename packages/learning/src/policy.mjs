import { canonicalJson } from "./canonical-json.mjs"
import { LearningError } from "./errors.mjs"

export const PURPOSES = Object.freeze([
  "review",
  "instruction",
  "evaluation",
  "analytics",
  "training",
  "publication",
])

/** Whether two scopes name exactly the same owner. */
export function sameScope(left, right) {
  return canonicalJson(left) === canonicalJson(right)
}

/** Refuse a record whose scope differs from the caller's. */
export function assertScope(context, record, label = "record") {
  if (!record || !sameScope(record.scope, context.scope))
    throw new LearningError(
      "scope_violation",
      `The ${label} belongs to a different scope than the caller.`,
    )
}

/**
 * Decides which purposes each piece of evidence may serve at one moment. A grant permits a
 * purpose when it names the purpose, has started, has not expired, and no withdrawal of that
 * purpose took effect. It covers a piece of evidence when it shares the evidence's scope,
 * names its episode's source, and its evidence bounds contain the evidence's own time.
 *
 * @param {{ grants: any[], withdrawals: any[], at: string }} input
 */
export function createEligibility({ grants, withdrawals, at }) {
  const withdrawn = new Map()
  for (const withdrawal of withdrawals) {
    if (withdrawal.withdrawnAt > at) continue
    const purposes = withdrawn.get(withdrawal.grantId) ?? new Set()
    for (const purpose of withdrawal.purposes) purposes.add(purpose)
    withdrawn.set(withdrawal.grantId, purposes)
  }

  function permits(grant, purpose) {
    return (
      grant.purposes.includes(purpose) &&
      grant.grantedAt <= at &&
      (!grant.expiresAt || at < grant.expiresAt) &&
      !withdrawn.get(grant.id)?.has(purpose)
    )
  }

  function covers(grant, episode, time) {
    return (
      sameScope(grant.scope, episode.scope) &&
      grant.sources.includes(episode.source.kind) &&
      (!grant.evidenceFrom || time >= grant.evidenceFrom) &&
      (!grant.evidenceUntil || time < grant.evidenceUntil)
    )
  }

  return {
    at,
    /** The purposes a grant still permits now. */
    activePurposes(grant) {
      return PURPOSES.filter((purpose) => permits(grant, purpose))
    },
    withdrawnPurposes(grant) {
      return [...(withdrawn.get(grant.id) ?? [])]
    },
    /** The grants that let evidence from this episode, written at this time, serve this purpose now. */
    grantsFor(episode, time, purpose) {
      return grants
        .filter((grant) => permits(grant, purpose) && covers(grant, episode, time))
        .map((grant) => grant.id)
    },
    evidenceEligible(episode, time, purpose) {
      return (
        Boolean(episode) &&
        grants.some((grant) => permits(grant, purpose) && covers(grant, episode, time))
      )
    },
    /** Whether any active grant in this scope permits the purpose for at least one source. */
    purposeGranted(scope, purpose) {
      return grants.some((grant) => sameScope(grant.scope, scope) && permits(grant, purpose))
    },
  }
}
