// Generates src/contracts-validators.cjs from the v1 JSON Schemas.
// Run `npm run schema:generate` after changing a schema; CI runs `npm run schema:check`.
import { readFile, readdir, writeFile } from "node:fs/promises"
import Ajv2020 from "ajv/dist/2020.js"
import { _Code } from "ajv/dist/compile/codegen/code.js"
import standaloneCode from "ajv/dist/standalone/index.js"
import { isTimestamp } from "./src/time.mjs"

const contracts = new URL("./contracts/v1/", import.meta.url)
const files = (await readdir(contracts)).filter((name) => name.endsWith(".schema.json")).sort()
const schemas = await Promise.all(
  files.map(async (name) => JSON.parse(await readFile(new URL(name, contracts), "utf8"))),
)

// strictRequired is off because if/then branches name properties declared by the parent.
const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
  strictRequired: false,
  inlineRefs: false,
  code: {
    source: true,
    esm: false,
    lines: false,
    // Embed the shared, self-contained date check so only schema-declared timestamps use it.
    formats: new _Code(`({ "date-time": ${isTimestamp.toString().replaceAll("\r\n", "\n")} })`),
  },
})
ajv.addFormat("date-time", isTimestamp)
for (const schema of schemas) ajv.addSchema(schema)

const validators = Object.fromEntries(
  schemas
    .filter((schema) => schema.$id && !schema.$id.endsWith("/common.schema.json"))
    .map((schema) => [validatorName(schema.$id), schema.$id]),
)

// Ajv's remaining runtime helper counts code points for minLength and maxLength.
// Inline an equivalent so the validators run with Node alone.
const LENGTH_HELPER = 'require("ajv/dist/runtime/ucs2length").default'
const source = standaloneCode(ajv, validators).replaceAll(
  LENGTH_HELPER,
  "function codePointLength(value) { let length = 0; for (const _ of value) length++; return length }",
)
if (/\brequire\(/.test(source))
  throw new Error(
    "Generated validators must not require runtime modules. Avoid uniqueItems and object enums.",
  )

const output =
  "// Generated from contracts/v1/*.schema.json. Run npm run schema:generate.\n" +
  "/* eslint-disable */\n" +
  source +
  "\n"
const destination = new URL("./src/contracts-validators.cjs", import.meta.url)
if (process.argv.includes("--check")) {
  if ((await readFile(destination, "utf8")) !== output)
    throw new Error("Learning contract validators are stale. Run npm run schema:generate.")
} else {
  await writeFile(destination, output)
}

function validatorName(id) {
  const name = id.split("/").pop().replace(".schema.json", "")
  return name.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())
}
