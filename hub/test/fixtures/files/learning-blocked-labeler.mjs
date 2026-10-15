import { existsSync, writeFileSync } from "node:fs"
import { createLabeler as createNormalLabeler } from "./labeler.mjs"

export function createLabeler() {
  const labeler = createNormalLabeler()
  return {
    ...labeler,
    async label(input) {
      writeFileSync(new URL("./label-started", import.meta.url), process.pid.toString())
      const deadline = Date.now() + 30_000
      while (!existsSync(new URL("./label-release", import.meta.url))) {
        if (Date.now() > deadline) throw new Error("The test did not release its labeler.")
        await new Promise((resolve) => setTimeout(resolve, 10))
      }
      return labeler.label(input)
    },
  }
}
