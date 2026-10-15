// A consolidator modeled on Dreaming in Agent Memory Repo
// (https://github.com/AgentMemoryRepo/agentmemoryrepo), written only against Replica's
// consolidator contract. It imports nothing from @github/replica-learning, so a team can copy it
// into its own repository and select it in .replica/learning/config.json:
//
//   { "schemaVersion": "replica.learning-config/v1",
//     "consolidation": { "consolidator": { "module": "./tools/dreaming.mjs" } } }

const PROPOSAL_SCHEMA = "replica.memory-proposal/v1"
const ID = "agent-memory-repo-dreaming"
const VERSION = "1"

export const DEFAULT_DREAMING_OPTIONS = Object.freeze({
  /** Word overlap at which two learnings say the same thing, whatever they cite. */
  sameText: 0.6,
  /** Share of cited comments two learnings must have in common to count as the same. */
  sameSources: 0.5,
  /** Word overlap they also need when they share their sources. */
  sameSourcesText: 0.2,
  /** Options for the recurrence consolidator, which does the adding. */
  recurrence: Object.freeze({}),
})

const STOP_WORDS = new Set(
  "about above after again all also and any are because been before but can each every for from has have its into just more most must only other our out over should some such than that the their them then there these they this those through use used uses using very was were what when where which while who will with would your".split(
    " ",
  ),
)
const NEGATIONS = new Set(["no", "not", "never", "without", "avoid", "cannot", "nor", "none"])

/**
 * Dreaming has two jobs. Adding memory proposes learnings from themes that recur across
 * review threads; the built-in recurrence consolidator does that, and Dreaming drops any new
 * proposal that repeats a learning in effect or a stronger proposal from the same run.
 * Cleaning up memory proposes merging accepted learnings that say the same thing, and reports
 * learnings that conflict, are outdated, or are contested so a person can decide. Unlike
 * Dreaming in Agent Memory Repo, it changes nothing itself: Replica stores what it returns as
 * proposals, and a person decides.
 *
 * Two learnings say the same thing only when their words or their sources overlap enough, and
 * they also agree in kind, in whether they say to do something or not to, in where they apply,
 * and in when they are valid, and no comment supports one while disputing the other. Similar
 * learnings that differ in any of these are reported as a conflict, never merged.
 *
 * @param {Partial<typeof DEFAULT_DREAMING_OPTIONS>} [options]
 * @param {{ createRecurrenceConsolidator?: (options?: object) => { consolidate: Function } }} [builtins]
 *   the built-in consolidators replica-learning passes to every consolidator module
 */
export function createConsolidator(options = {}, builtins = {}) {
  const settings = { ...DEFAULT_DREAMING_OPTIONS, ...options }
  for (const key of ["sameText", "sameSources", "sameSourcesText"])
    if (typeof settings[key] !== "number" || !(settings[key] > 0 && settings[key] <= 1))
      throw new Error(`${key} must be a number above 0 and at most 1.`)
  if (typeof builtins.createRecurrenceConsolidator !== "function")
    throw new Error(
      "Load this consolidator through replica-learning, which passes the built-in consolidators, or pass { createRecurrenceConsolidator } as the second argument.",
    )
  const adding = builtins.createRecurrenceConsolidator(settings.recurrence)

  return {
    manifest: {
      id: ID,
      version: VERSION,
      description:
        "Agent Memory Repo Dreaming: proposes recurring themes and merges of duplicate learnings, and reports conflicting, outdated, or contested ones.",
      settings: structuredClone(settings),
    },

    async consolidate(request, view) {
      const added = await adding.consolidate(request, view)
      const current = view.memories.filter(
        (memory) => memory.state === "accepted" && memory.effective && memory.content,
      )
      const diagnostics = [...(added.diagnostics ?? [])]
      const proposals = []
      for (const proposal of added.proposals) {
        const label = proposal.themeKey ?? "this theme"
        const repeated =
          current.find((memory) => relation(proposal, memory, settings)?.same)?.id ??
          proposals.find((kept) => relation(proposal, kept, settings)?.same)?.themeKey
        if (repeated) {
          diagnostics.push({
            code: "already_covered",
            themeKey: proposal.themeKey,
            message: `${repeated} already says this, so no separate learning is proposed for ${label}.`,
          })
          continue
        }
        for (const memory of current) {
          const reasons = relation(proposal, memory, settings)?.conflict
          if (reasons)
            diagnostics.push({
              code: "disagrees_with_current",
              themeKey: proposal.themeKey,
              message: `The proposal for ${label} resembles ${memory.id}, but ${reasons.join(", and ")}. A person should decide which applies.`,
            })
        }
        proposals.push(proposal)
      }
      const cleaned = cleanUp(current, settings, view)
      proposals.push(...cleaned.proposals)
      diagnostics.push(
        ...cleaned.diagnostics,
        ...outdated(view.memories),
        ...contested(current, view.events),
      )
      return { proposals, diagnostics }
    },
  }
}

/**
 * Merge proposals for groups of accepted learnings that say the same thing, and notes for
 * pairs that look alike but conflict. A group that contains a conflict is not merged.
 */
function cleanUp(memories, settings, view) {
  const parent = new Map(memories.map((memory) => [memory.id, memory.id]))
  function root(id) {
    while (parent.get(id) !== id) id = parent.get(id)
    return id
  }
  const conflicts = []
  for (const [index, left] of memories.entries())
    for (const right of memories.slice(index + 1)) {
      const found = relation(left, right, settings)
      if (found?.same) parent.set(root(right.id), root(left.id))
      if (found?.conflict) conflicts.push({ ids: [left.id, right.id], reasons: found.conflict })
    }
  const groups = new Map()
  for (const memory of memories) {
    const key = root(memory.id)
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(memory)
  }
  const proposals = []
  const diagnostics = conflicts.map(({ ids, reasons }) => ({
    code: "conflicting_learnings",
    message: `${ids.join(" and ")} look alike, but ${reasons.join(", and ")}. A person should decide which applies, and retire or keep each one.`,
  }))
  for (const group of [...groups.values()].filter((members) => members.length > 1)) {
    group.sort((a, b) => compare(a.id, b.id))
    const ids = group.map((memory) => memory.id)
    const inside = conflicts.some((conflict) => conflict.ids.every((id) => ids.includes(id)))
    const proposal = inside ? null : merge(group, view)
    if (proposal) proposals.push(proposal)
    else
      diagnostics.push({
        code: "merge_held_back",
        message: `${ids.join(", ")} say much the same thing, but some of them conflict, so no merge is proposed. A person should resolve them.`,
      })
  }
  return { proposals, diagnostics }
}

/** Whether two learnings say the same thing, conflict, or are unrelated (null). */
function relation(left, right, settings) {
  const text = overlap(words(left.content), words(right.content))
  const sources = overlap(cited(left.evidence), cited(right.evidence))
  if (
    text < settings.sameText &&
    !(sources >= settings.sameSources && text >= settings.sameSourcesText)
  )
    return null
  const reasons = []
  if (left.kind !== right.kind) reasons.push("they are different kinds of learning")
  if (polarity(left.content) !== polarity(right.content))
    reasons.push("one says not to do what the other says to do")
  if (disjoint(left.appliesTo, right.appliesTo)) reasons.push("they apply to different places")
  if (lifetime(left) !== lifetime(right)) reasons.push("they are valid for different periods")
  if (crosses(left, right) || crosses(right, left))
    reasons.push("comments that support one dispute the other")
  return reasons.length ? { conflict: reasons } : { same: true }
}

/** One proposal that replaces a group with the wording of its best-supported learning. */
function merge(group, view) {
  const keeper = [...group].sort(
    (a, b) =>
      (b.support?.distinctReviewers ?? 0) - (a.support?.distinctReviewers ?? 0) ||
      (b.support?.distinctEpisodes ?? 0) - (a.support?.distinctEpisodes ?? 0) ||
      compare(a.id, b.id),
  )[0]
  const ids = group.map((memory) => memory.id)
  const evidence = distinctReferences(group.flatMap((memory) => memory.evidence))
  const contradictions = distinctReferences(group.flatMap((memory) => memory.contradictions ?? []))
  const supporting = cited(evidence)
  if (contradictions.some((reference) => reference.eventIds.some((id) => supporting.has(id))))
    return null
  const traces = new Map()
  for (const memory of group)
    for (const trace of memory.appliesTo ?? []) traces.set(`${trace.kind} ${trace.ref}`, trace)
  const themeKey = keeper.themeKey ?? group.find((memory) => memory.themeKey)?.themeKey
  return {
    schemaVersion: PROPOSAL_SCHEMA,
    kind: keeper.kind,
    content: keeper.content,
    ...(themeKey ? { themeKey } : {}),
    ...(traces.size
      ? {
          appliesTo: [...traces.entries()]
            .sort(([a], [b]) => compare(a, b))
            .map(([, trace]) => trace)
            .slice(0, 20),
        }
      : {}),
    evidence,
    ...(contradictions.length ? { contradictions } : {}),
    ...Object.fromEntries(
      ["validFrom", "validUntil", "expiresAt"]
        .filter((key) => keeper[key] !== undefined)
        .map((key) => [key, keeper[key]]),
    ),
    support: supportOf(evidence, view.episodes),
    rationale: {
      recurrence: `${ids.length} accepted learnings say the same thing: ${ids.join(", ")}. Dreaming keeps the wording of ${keeper.id}, which has the most support, and cites the evidence and counterevidence of all of them.`,
      ...(contradictions.length
        ? {
            contradictions: `${contradictions.length} comment(s) disagreed with the merged learnings; see contradictions.`,
          }
        : {}),
      expectedBenefit: `One learning instead of ${ids.length}, so recall spends its budget on guidance that differs.`,
      falsification:
        "Reject this if the learnings cover different situations, and keep them separate.",
    },
    lifecycle: { action: "merge", targets: ids },
    consolidator: { id: ID, version: VERSION },
  }
}

/** Accepted learnings that no longer apply. Replica has no retire proposal, so a person retires them. */
function outdated(memories) {
  return memories
    .filter(
      (memory) =>
        memory.state === "accepted" &&
        !memory.superseded &&
        (memory.needsRebuild || memory.expired),
    )
    .map((memory) => ({
      code: "retire_suggested",
      themeKey: memory.themeKey,
      message: `${memory.id} no longer applies: ${memory.needsRebuild ? "its evidence was withdrawn or retracted" : "it expired"}. If a person agrees, they run: replica-learning retire ${memory.id} --by github:<login> --reason "<why>".`,
    }))
}

/** Learnings in effect that as many reviewers now contradict as support. */
function contested(memories, events) {
  const comments = new Map(events.map((event) => [event.id, event]))
  const latest = new Map()
  for (const event of events)
    if (event.type === "annotation")
      latest.set(`${event.payload.target.eventId}\u0000${event.actor.id}`, event)
  const stances = new Map()
  for (const label of latest.values()) {
    const comment = comments.get(label.payload.target.eventId)
    if (!comment || comment.type !== "human_comment") continue
    const key = label.payload.theme.key
    if (!stances.has(key)) stances.set(key, { supports: new Set(), contradicts: new Set() })
    stances
      .get(key)
      [label.payload.stance === "contradicts" ? "contradicts" : "supports"].add(comment.actor.id)
  }
  const found = []
  for (const memory of memories) {
    const theme = memory.themeKey ? stances.get(memory.themeKey) : undefined
    if (!theme?.contradicts.size || theme.contradicts.size < theme.supports.size) continue
    found.push({
      code: "contested",
      themeKey: memory.themeKey,
      message: `${theme.contradicts.size} reviewer(s) now disagree with ${memory.id} and ${theme.supports.size} agree. A person should review it.`,
    })
  }
  return found
}

function supportOf(evidence, episodes) {
  const byId = new Map(episodes.map((episode) => [episode.id, episode]))
  const prototypes = new Set()
  const builds = new Set()
  const reviewers = new Set()
  for (const reference of evidence) {
    const source = reference.source ?? byId.get(reference.episodeId)?.source ?? {}
    const prototype =
      source.prototypeId === undefined
        ? `episode:${reference.episodeId}`
        : `${source.hubOrigin}#${source.prototypeId}`
    prototypes.add(prototype)
    if (source.buildNumber !== undefined) builds.add(`${prototype}#${source.buildNumber}`)
    if (reference.author) reviewers.add(reference.author.id)
  }
  return {
    distinctEpisodes: new Set(evidence.map((reference) => reference.episodeId)).size,
    distinctPrototypes: prototypes.size,
    distinctReviewers: reviewers.size,
    distinctBuilds: builds.size,
  }
}

function distinctReferences(references) {
  const seen = new Map()
  for (const reference of references) seen.set(referenceKey(reference), reference)
  return [...seen.values()].sort(
    (a, b) => compare(a.episodeId, b.episodeId) || compare(a.eventIds[0], b.eventIds[0]),
  )
}

function referenceKey(reference) {
  return `${reference.episodeId}\u0000${[...reference.eventIds].sort().join(",")}`
}

function cited(references = []) {
  return new Set(references.flatMap((reference) => reference.eventIds))
}

/** Whether a learning's counterevidence cites what another learning cites as support. */
function crosses(left, right) {
  const disputed = cited(left.contradictions)
  return [...cited(right.evidence)].some((id) => disputed.has(id))
}

function disjoint(left = [], right = []) {
  if (!left.length || !right.length) return false
  const places = new Set(left.map((trace) => `${trace.kind} ${trace.ref}`))
  return !right.some((trace) => places.has(`${trace.kind} ${trace.ref}`))
}

function lifetime(memory) {
  return [memory.validFrom, memory.validUntil, memory.expiresAt]
    .map((value) => value ?? "")
    .join("|")
}

function tokens(text = "") {
  return text
    .toLowerCase()
    .replace(/n['\u2019]t\b/g, " not")
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
}

function words(text) {
  return new Set(
    tokens(text).filter((word) => word.length > 2 && !STOP_WORDS.has(word) && !NEGATIONS.has(word)),
  )
}

/** Whether a learning says not to do something: an odd number of negations. */
function polarity(text) {
  return tokens(text).filter((word) => NEGATIONS.has(word)).length % 2
}

function overlap(left, right) {
  if (!left.size || !right.size) return 0
  let shared = 0
  for (const item of left) if (right.has(item)) shared++
  return shared / (left.size + right.size - shared)
}

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}
