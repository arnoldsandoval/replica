# Agent Memory Repo example

[Agent Memory Repo](https://github.com/AgentMemoryRepo/agentmemoryrepo) is an open format for agent memory, released by Cognition under the MIT license. Memory is a Git repo of Markdown files. `MEMORY.md` is the short entry point, each entry is one bullet with `[key: value]` metadata at the end, and `[[path]]` links files together. A periodic agent called Dreaming adds patterns it spots across sessions and cleans up the rest: it merges duplicates, removes outdated entries, and checks sources to resolve contradictions.

This example plugs that format into Replica's learning loop in two places. It is also a template for anyone who wants to bring their own consolidator.

| Agent Memory Repo | Replica | This example |
| --- | --- | --- |
| Dreaming adds new memory | A consolidator's proposals | `dreaming.mjs` runs the built-in recurrence consolidator and drops proposals that repeat a learning in effect |
| Dreaming merges duplicates | A merge proposal | `dreaming.mjs` proposes one merge for each group of accepted learnings that say the same thing, and reports look-alikes that conflict |
| Dreaming removes outdated entries | A person retires a learning | `dreaming.mjs` reports learnings whose evidence was withdrawn or that expired |
| Dreaming checks sources for contradictions | Counterevidence | `dreaming.mjs` reports learnings that as many reviewers contradict as support |
| A memory repo other agents read | An export destination | `publish.mjs` writes each repository's accepted learnings to its own file under `replica/` and links it from `MEMORY.md` |

## Dreaming as a consolidator

`dreaming.mjs` uses only the consolidator contract and imports nothing from this package, so it works when copied into a prototype repository:

```sh
mkdir -p tools
cp <replica-checkout>/packages/learning/examples/agent-memory-repo/dreaming.mjs tools/
```

Then select it in `.replica/learning/config.json`:

```json
{
  "schemaVersion": "replica.learning-config/v1",
  "consolidation": { "consolidator": { "module": "./tools/dreaming.mjs" } }
}
```

`replica-learning consolidate` passes the module the built-in consolidators, and Dreaming uses the recurrence consolidator for its adding job. Two accepted learnings look alike when their meaningful words overlap by at least 60 percent, counted as shared words over all distinct words, or when half of the comments they cite are shared and their words overlap by at least 20 percent. Change these with `consolidation.options`: `sameText`, `sameSources`, and `sameSourcesText`. `recurrence` holds the recurrence consolidator's own options.

Looking alike is not enough to merge. The two must also be the same kind of learning, both say to do something or both say not to, apply to at least one of the same places when both name places, and have the same validity dates. No comment may support one while disputing the other. When any of these fails, Dreaming reports the pair as conflicting and proposes nothing, so a person decides which applies. The negation check counts words such as not, never, and avoid, so unusual phrasing can still fool it; that is one more reason a person reviews every merge. A merge keeps the wording and validity dates of the learning with the most reviewers, and cites the evidence and counterevidence of all of them.

Dreaming in Agent Memory Repo edits memory itself. Here it only proposes. A designer reads each merge with `replica-learning show` and accepts or rejects it, and a person runs `replica-learning retire` for a learning Dreaming reports as outdated. Replica has no retire proposal in version 1. Dreaming also runs only when someone runs `consolidate`; scheduling it needs a job outside this package.

## Publishing to a memory repo

Run the publisher from the prototype repository, the same way as the command:

```sh
node <replica-checkout>/packages/learning/examples/agent-memory-repo/publish.mjs \
  --memory-repo ~/agent-memory --by github:<login>
```

It follows the format's own ground rules. The memory repo must be separate from the project, and the publisher creates it if the directory is missing or empty. It refuses a directory that is not its own Git repo with `MEMORY.md` at the top, and a memory repo with uncommitted changes. It refuses to write through a symbolic link, even one committed to the memory repo, so it cannot be pointed at a served or unrelated directory. It ignores Git variables such as `GIT_DIR` that would aim Git at another repository, and checks that Git resolves the memory repo itself before each commit. It stages only `MEMORY.md` and the repository's topic file, commits locally, and never pushes.

Each repository gets its own topic file, such as `replica/github.com/acme/checkout-prototypes.md`, so several projects can publish to one memory repo. An agent then reads the learnings with the [Agent Memory Repo skill](https://github.com/AgentMemoryRepo/agentmemoryrepo/blob/main/skills/agent-memory-repo/SKILL.md), as it would any other memory.

Each accepted learning becomes one line:

```markdown
- Show a visible label above every form field; never use placeholder text as the only label. [source: replica:github.com/acme/checkout-prototypes/mem_7eb35ba21bbe6c45a9a296b4; added: 2026-10-06; kind: rule; applies: skill .agents/skills/create-prototype/SKILL.md]
```

## What stays the same as the rest of Replica

- The copy goes through an instruction export that holds learnings alone, so review comments and reviewer names never reach the memory repo. The export manifest records which learnings left.
- Withdrawing instruction lists the memory repo among the exports to follow up, because the export records the grants that permitted it. Publishing again rewrites the repository's file without the learnings that may no longer be used, and with no grant at all it lists none.
- Git history keeps every earlier version of the file. Removing published text from history means rewriting it or starting a new memory repo, so push only to a private remote you control, and only learnings you would be comfortable having to retract.
- The file is generated. Edits made in the memory repo are overwritten on the next publish, so change a learning in Replica.
- The memory repo is not Replica's record store. Its entries are editable Markdown without versions, digests, or consent records, so Replica keeps its records in its own provider and treats the memory repo as a place it publishes to.
- Nothing is deleted from Replica. Its records are append-only, so cleaning up means a person accepts a merge or retires a learning, and recall stops using what was replaced or retired.

## Try it

```sh
npm run demo:agent-memory-repo
```

The demo builds a temporary checkout and memory repo. Two labeling passes file the same comments under different themes, and a designer accepts both. The team then selects Dreaming, which proposes one merge. After the designer accepts it, the publisher writes the learning to the memory repo. A withdrawal lists that copy for follow-up, Dreaming reports the learning as outdated, and publishing again removes it. `test/agent-memory-repo.test.mjs` covers each step.
