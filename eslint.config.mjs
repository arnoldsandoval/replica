import hubConfig from "./hub/eslint.config.ts"

export default hubConfig.map((config) =>
  config.files?.includes("../.github/extensions/replica-prototype/**/*.mjs")
    ? {
        ...config,
        files: config.files.map((pattern) =>
          pattern.startsWith("../") ? pattern.slice(3) : `hub/${pattern}`,
        ),
      }
    : config,
)
