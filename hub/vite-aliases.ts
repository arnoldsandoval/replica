import { fileURLToPath, URL } from "node:url"

export const viteAliases = {
  "@": fileURLToPath(new URL("./app/javascript", import.meta.url)),
  "@application": fileURLToPath(new URL("./app/javascript/application", import.meta.url)),
  "@components": fileURLToPath(new URL("./app/javascript/components", import.meta.url)),
  "@features": fileURLToPath(new URL("./app/javascript/features", import.meta.url)),
  "@hooks": fileURLToPath(new URL("./app/javascript/hooks", import.meta.url)),
  "@pages": fileURLToPath(new URL("./app/javascript/pages", import.meta.url)),
  "@utils": fileURLToPath(new URL("./app/javascript/utils", import.meta.url)),
}
