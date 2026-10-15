import { execFileSync } from "node:child_process"

const pluginName = "replica-prototype"
const pluginId = `${pluginName}@replica`
const enableHelp =
  "Open Customization, select Installed in the top-left bar, and enable both the Replica plugin and the Replica extension. Start a fresh Copilot session if the canvas is still missing."

function cli(args, timeout = 10_000) {
  return execFileSync("copilot", ["plugin", ...args], {
    encoding: "utf8",
    timeout,
    stdio: ["ignore", "pipe", "pipe"],
  })
}

function list(args) {
  const entries = JSON.parse(cli([...args, "list", "--json"]))
  if (!Array.isArray(entries)) {
    throw new Error("Copilot returned an unsupported plugin list. Check the installed CLI version.")
  }
  return entries
}

function installedPlugin() {
  const matches = list([]).filter((plugin) => plugin.name === pluginName)
  if (matches.length === 0) return undefined
  if (
    matches.length !== 1 ||
    matches[0].marketplace !== "replica" ||
    matches[0].source !== "installed" ||
    typeof matches[0].enabled !== "boolean"
  ) {
    throw new Error("A different or ambiguous Replica installation exists. Review it before setup.")
  }
  return matches[0]
}

function setup() {
  const installed = installedPlugin()
  if (installed?.enabled) return

  if (!installed) {
    const marketplaces = list(["marketplace"]).filter(
      (marketplace) => marketplace.name === "replica",
    )
    if (
      marketplaces.length > 1 ||
      (marketplaces.length === 1 &&
        !/^GitHub: github\/replica(?:#[^\s]+)?$/.test(marketplaces[0].source))
    ) {
      throw new Error(
        "The replica marketplace source could not be verified as github/replica. Review it before setup.",
      )
    }
    if (marketplaces.length === 0) {
      cli(["marketplace", "add", "github/replica"], 60_000)
    }
    cli(["install", pluginId], 60_000)
  } else {
    cli(["enable", pluginId])
  }

  const result = installedPlugin()
  if (!result?.enabled) {
    throw new Error("Copilot did not report the Replica plugin installed and enabled after setup.")
  }
  console.log(`Replica plugin enabled for future sessions. ${enableHelp}`)
}

try {
  setup()
} catch (error) {
  console.error(`Replica plugin setup failed: ${error.message}`)
  console.error(
    `Check the session setup output and CLI access or organization policy. ${enableHelp}`,
  )
  process.exitCode = 1
}
