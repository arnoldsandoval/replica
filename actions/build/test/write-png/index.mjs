import { writeFile } from "node:fs/promises"

import pngjs from "pngjs"

/** Writes a blank PNG with the dimensions needed by a package test. */
export async function writePng(filePath, width, height) {
  const image = new pngjs.PNG({ width, height })
  await writeFile(filePath, pngjs.PNG.sync.write(image))
}
