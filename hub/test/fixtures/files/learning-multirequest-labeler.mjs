import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs"
import { createLabeler as createNormalLabeler } from "./labeler.mjs"

export function createLabeler() {
  const labeler = createNormalLabeler()
  const requests = new URL("./label-requests.jsonl", import.meta.url)
  const mode = readFileSync(new URL("./label-mode", import.meta.url), "utf8")
  return {
    ...labeler,
    async label(input) {
      const comments = input.threads.flatMap((thread) =>
        thread.comments.filter((comment) => comment.label).map((comment) => comment.id),
      )
      appendFileSync(requests, `${JSON.stringify({ pid: process.pid, comments })}\n`)
      const count = readFileSync(requests, "utf8").trim().split("\n").length
      if (count === 1 && mode === "pause-first") {
        writeFileSync(new URL("./label-started", import.meta.url), process.pid.toString())
        const deadline = Date.now() + 30_000
        while (!existsSync(new URL("./label-release", import.meta.url))) {
          if (Date.now() > deadline) throw new Error("The test did not release its labeler.")
          await new Promise((resolve) => setTimeout(resolve, 10))
        }
      }
      if (count === 2 && mode === "fail-second") {
        throw new Error("The second model request failed.")
      }
      if (count === 2 && mode === "unauthorized-usage") {
        throw Object.assign(new Error("Synthetic token refused."), {
          code: "unauthorized",
          details: { usage: [{ model: "test-model", nanoAiu: 1.5 }] },
        })
      }
      return labeler.label(input)
    },
    close() {
      if (mode === "fail-close") throw new Error("The model runtime could not close.")
    },
  }
}
