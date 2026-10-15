import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"
import type { Plugin } from "vite"

const root = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "./app/javascript/utils/prototype-controls",
)
export const controlsValidatorModule = "replica-controls-validator"
export const controlsValidatorPath = resolve(root, "controls-shape.cjs")

export function controlsValidatorPlugin(): Plugin {
  return {
    name: "replica:controls-validator",
    enforce: "pre",
    resolveId(source, importer, options) {
      if (
        source !== "./controls-shape.cjs" ||
        importer?.split("?")[0] !== resolve(root, "controls-validation.mjs")
      )
        return null
      return this.resolve(controlsValidatorModule, importer, { ...options, skipSelf: true })
    },
  }
}
