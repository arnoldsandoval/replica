import { lstat, readFile } from "node:fs/promises"
import path from "node:path"

import { MAX_TEMPLATE_MANIFEST_BYTES } from "../constants.mjs"
import { validateTemplates } from "../validate-templates/index.mjs"

/** Reads optional template metadata without following a linked configuration file. */
export async function readTemplates(root, filename = ".github/replica.json") {
  const segments = filename.split("/")
  let details
  for (let index = 1; index <= segments.length; index++) {
    try {
      details = await lstat(path.join(root, ...segments.slice(0, index)))
    } catch (error) {
      if (error.code === "ENOENT") return null

      throw error
    }

    if (index < segments.length ? !details.isDirectory() : !details.isFile()) {
      throw new Error(`${filename} must be a regular file without symbolic links.`)
    }
  }

  if (details.size > MAX_TEMPLATE_MANIFEST_BYTES) {
    throw new Error(`${filename} must be at most ${MAX_TEMPLATE_MANIFEST_BYTES} bytes.`)
  }

  const bytes = await readFile(path.join(root, filename))
  if (bytes.length > MAX_TEMPLATE_MANIFEST_BYTES) {
    throw new Error(`${filename} must be at most ${MAX_TEMPLATE_MANIFEST_BYTES} bytes.`)
  }

  let value
  try {
    value = JSON.parse(bytes.toString("utf8"))
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error

    throw new Error(`${filename} must contain correctly formatted JSON.`, { cause: error })
  }

  return validateTemplates(value)
}
