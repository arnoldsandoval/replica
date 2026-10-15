// A provider that keeps Node running until it is closed, the way a database pool does. The
// command must close it, or a process that runs the command never exits.
import { createMemoryProvider as createJsonFileProvider } from "./json-file-provider.mjs"

export function createMemoryProvider(options) {
  const provider = createJsonFileProvider(options)
  const connection = setInterval(() => {}, 1000)
  return {
    ...provider,
    async close() {
      clearInterval(connection)
      await provider.close?.()
    },
  }
}
