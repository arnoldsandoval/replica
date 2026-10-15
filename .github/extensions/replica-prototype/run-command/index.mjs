import { execFile } from "node:child_process"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

export async function runCommand(command, args, cwd, options = {}) {
  try {
    const { stdout } = await execFileAsync(command, args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
      timeout: 10_000,
      windowsHide: true,
      env: options.env,
    })
    return { ok: true, stdout }
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { ok: false, error: `${command} is not installed.` }
    }

    const detail =
      typeof error?.stderr === "string" && error.stderr.trim()
        ? error.stderr.trim()
        : error instanceof Error
          ? error.message
          : String(error)
    return {
      ok: false,
      error: detail,
      exitCode: error.code,
      stdout: typeof error.stdout === "string" ? error.stdout : "",
      stderr: typeof error.stderr === "string" ? error.stderr : "",
    }
  }
}
