import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"
import RubyPlugin from "vite-plugin-ruby"

import { viteAliases } from "./vite-aliases.ts"
import {
  controlsValidatorPlugin,
  controlsValidatorModule,
  controlsValidatorPath,
} from "./controls-validator-plugin.ts"

export default defineConfig({
  plugins: [RubyPlugin(), react(), controlsValidatorPlugin()],
  server: { hmr: { clientPort: 3036 } },
  resolve: { alias: { ...viteAliases, [controlsValidatorModule]: controlsValidatorPath } },
  optimizeDeps: { include: [controlsValidatorModule] },
})
