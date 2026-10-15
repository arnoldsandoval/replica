// Stands in for replica-learning in Hub's tests, so they run Hub's real process handling without
// Copilot. It answers from its arguments and the environment Hub passes.
import { spawn } from "node:child_process"
import { existsSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const [command, sub, size, held] = process.argv.slice(2).filter((argument) => argument !== "--json")
const token = process.env.COPILOT_GITHUB_TOKEN

function answer(value) {
  process.stdout.write(JSON.stringify(value))
  process.exit(0)
}

function refuse(code, message, exitCode = 1) {
  process.stderr.write(`error (${code}): ${message}\n`)
  process.exit(exitCode)
}

// Starts a process outside this command's group, as a runtime that escaped it would be, that keeps
// the command's standard output, and its standard error when asked, open for 8 seconds.
function holdOutput({ errors = true } = {}) {
  spawn(process.execPath, ["-e", "setTimeout(() => {}, 8000)"], {
    detached: true,
    stdio: ["ignore", "inherit", errors ? "inherit" : "ignore"],
  }).unref()
}

if (command === "copilot" && sub === "status") {
  if (token === "copilot-user-token" || token === "renewed-user-token")
    answer({
      signedIn: true,
      via: "token",
      login: null,
      host: "https://github.com",
      models: ["auto"],
    })
  if (token === "no-copilot-token") refuse("unauthorized", "Copilot refused the request: 403")
  if (token === "uninstalled-token") await import("@github/replica-package-that-is-not-installed")
  refuse("unavailable", "Copilot did not answer: the test runtime is offline.")
}
if (command === "environment")
  answer({ variables: Object.keys(process.env).sort(), token: token ?? null })
if (command === "directory") answer({ directory: process.cwd() })
if (command === "missing") {
  // Fails as replica-learning does when its packages are not installed: the CLI's own report of a
  // missing Copilot SDK, or Node's error for any other missing package.
  if (sub === "sdk")
    refuse(
      "unsupported",
      "Labeling with Copilot needs @github/copilot-sdk. Run npm ci in packages/learning.",
    )
  await import("@github/replica-package-that-is-not-installed")
}
if (command === "garbled") {
  process.stdout.write("not JSON")
  process.exit(0)
}
if (command === "garbled-error") {
  // Fails with error output that is not valid UTF-8.
  process.stderr.write(Buffer.from([0x65, 0x72, 0x72, 0xff, 0xfe, 0x0a]))
  process.exit(1)
}
if (
  command === "label" &&
  [
    "partial",
    "partial-invalid",
    "partial-unsafe",
    "partial-uncertain",
    "partial-cleanup",
    "partial-usage",
    "partial-invalid-note",
    "partial-auth-invalid",
    "partial-auth-garbled",
  ].includes(sub)
) {
  const report = {
    considered: 2,
    labeled: 2,
    remaining: 3,
    models: ["test-model"],
    usage: { requests: 1, inputTokens: 120, outputTokens: 30, nanoAiu: 5_000_000 },
    error: { code: "copilot_unavailable", message: "The next model request failed." },
  }
  if (sub === "partial-invalid") report.usage.requests = -1
  if (sub === "partial-unsafe") report.usage.nanoAiu = Number.MAX_SAFE_INTEGER + 1
  if (sub === "partial-invalid-note") report.usageError = []
  if (sub === "partial-auth-invalid") {
    report.error.code = "unauthorized"
    report.usage.nanoAiu = 1.5
  }
  if (sub === "partial-auth-garbled") {
    await new Promise((resolve) => process.stdout.write("not JSON", resolve))
    refuse("unauthorized", "Synthetic token refused.")
  }
  if (sub === "partial-usage") {
    report.error.code = "unauthorized"
    report.usageError = "Some usage from the failed request is unknown."
  }
  if (sub === "partial-uncertain")
    report.progressError = "Pending comment counts could not be verified."
  if (sub === "partial-cleanup") {
    report.error.code = "unauthorized"
    report.cleanupError = "The Copilot runtime could not be closed."
  }
  await new Promise((resolve) => process.stdout.write(JSON.stringify(report), resolve))
  refuse(report.error.code, report.error.message)
}
if (command === "flood") {
  // Writes a JSON answer whose text has the given number of two-byte characters to the stream it
  // names, then exits. Hub reads such an answer in pieces that can split a character. With
  // "held", a process outside the group first takes hold of standard output.
  if (held === "held") holdOutput({ errors: false })
  const stream = sub === "stderr" ? process.stderr : process.stdout
  stream.write(`{"text":"${"é".repeat(Number(size))}"}`, () => process.exit(0))
} else if (command === "stash") {
  // Keeps state under the temporary directory, as the Copilot labeler does, says where in a file in
  // the working directory, and waits for Hub to stop it before it can clean up.
  const state = mkdtempSync(path.join(tmpdir(), "replica-learning-copilot-"))
  writeFileSync(path.join(state, "session.json"), "{}")
  writeFileSync("stashed", state)
  setTimeout(() => answer({ stashed: state }), 60_000)
} else if (command === "hold-lock") {
  writeFileSync(sub, process.pid.toString())
  setInterval(() => {
    if (existsSync(size)) answer({ released: true })
  }, 10)
  setTimeout(() => refuse("timeout", "The test did not release its writer."), 30_000).unref()
} else if (command === "linger") {
  holdOutput()
  setTimeout(() => answer({ lingered: true }), 60_000)
} else if (command === "wait") setTimeout(() => answer({ waited: true }), 60_000)
else refuse("invalid_input", `The test command does not know ${command}.`, 2)
