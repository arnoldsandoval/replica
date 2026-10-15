import { mkdir, writeFile } from "node:fs/promises"

await mkdir("dist", { recursive: true })
await writeFile(
  "dist/index.html",
  '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Replica fixture</title></head><body><main><h1>Replica fixture</h1></main></body></html>',
)
