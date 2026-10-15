#!/usr/bin/env node
// Publishes the accepted design learnings of the current checkout to an Agent Memory Repo.
// Run it from the prototype repository, the same way as the replica-learning command:
//
//   node <replica>/packages/learning/examples/agent-memory-repo/publish.mjs \
//     --memory-repo ~/agent-memory --by github:<login>
import { realpathSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { parseArgs } from "node:util"
import { openLearningStore, resolveEnvironment } from "../../src/config.mjs"
import { publishToMemoryRepo } from "./memory-repo.mjs"

const USAGE = `publish.mjs: copy accepted design learnings into an Agent Memory Repo.

Usage: node publish.mjs --memory-repo <path> --by github:<login> [--dir <data dir>]

Run it from the prototype repository. It exports the learnings an instruction grant permits,
writes them to replica/design-learnings.md in the memory repo, links that file from MEMORY.md,
and commits locally. The memory repo must be outside the project. It never pushes.
`

/**
 * @param {string[]} argv
 * @param {{ cwd?: string, env?: Record<string, string | undefined>, stdout?: { write(text: string): void }, stderr?: { write(text: string): void }, clock?: () => number }} [io]
 */
export async function main(
  argv,
  {
    cwd = process.cwd(),
    env = process.env,
    stdout = process.stdout,
    stderr = process.stderr,
    clock = Date.now,
  } = {},
) {
  let values
  try {
    ;({ values } = parseArgs({
      args: argv,
      options: {
        "memory-repo": { type: "string" },
        by: { type: "string" },
        dir: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
      strict: true,
    }))
  } catch (error) {
    stderr.write(`${error.message}\n\n${USAGE}`)
    return 2
  }
  if (values.help) {
    stdout.write(USAGE)
    return 0
  }
  if (!values["memory-repo"] || !values.by) {
    stderr.write(USAGE)
    return 2
  }
  if (!/^(?:github|human):\S+$/.test(values.by)) {
    stderr.write("Only a person can publish learnings. Pass --by github:<login>.\n")
    return 1
  }
  let store
  try {
    const environment = await resolveEnvironment({ cwd, env, directory: values.dir })
    store = (await openLearningStore(environment, { clock })).store
    const result = await publishToMemoryRepo({
      store,
      context: {
        scope: environment.scope,
        principal: { kind: "human", id: values.by, asserted: true },
      },
      memoryRepo: values["memory-repo"],
      checkout: environment.root,
      gitEnv: env,
    })
    stdout.write(
      [
        `Published ${result.learnings} learning(s) to ${result.file}.`,
        result.commit ? `Committed ${result.commit} in ${result.memoryRepo}.` : "Nothing changed.",
        result.exportId
          ? `Export ${result.exportId} records what left the store.`
          : "No grant permits instruction, so the file lists no learnings.",
        "Nothing was pushed.",
      ].join("\n") + "\n",
    )
    return 0
  } catch (error) {
    stderr.write(`error${error.code ? ` (${error.code})` : ""}: ${error.message}\n`)
    return 1
  } finally {
    await store?.close()
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url))
  process.exitCode = await main(process.argv.slice(2))
