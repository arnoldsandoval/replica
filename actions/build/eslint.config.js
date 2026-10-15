import js from "@eslint/js"
import { defineConfig } from "eslint/config"
import prettier from "eslint-config-prettier"
import globals from "globals"

export default defineConfig(
  {
    ignores: ["node_modules/**", "test/fixture/dist/**"],
  },
  js.configs.recommended,
  {
    files: ["**/*.mjs"],
    languageOptions: {
      globals: { ...globals.browser, ...globals.node },
    },
    rules: {
      "func-style": ["error", "declaration"],
      quotes: ["error", "double", { avoidEscape: true }],
      semi: ["error", "never"],
    },
  },
  prettier,
)
