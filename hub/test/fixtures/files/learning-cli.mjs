import { main } from "../../../../packages/learning/src/cli.mjs"

// Keep the real CLI on Rails' test clock when a case advances time between snapshots.
process.exitCode = await main(process.argv.slice(2), {
  clock: () => Date.parse(process.env.REPLICA_LEARNING_TEST_CLOCK),
})
