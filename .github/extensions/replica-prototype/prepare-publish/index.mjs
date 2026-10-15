import { capturePublishTarget, samePublishTarget } from "../publish-target/index.mjs"
import { runCommand } from "../run-command/index.mjs"

export async function preparePublish(context, preferences) {
  const target = await capturePublishTarget(context)
  const status = await runCommand(
    "git",
    ["status", "--porcelain", "--untracked-files=normal"],
    context.repositoryPath,
  )
  if (!status.ok) throw new Error(`Could not check uncommitted changes: ${status.error}`)
  const remember = await preferences.read(target)
  if (!samePublishTarget(target, await capturePublishTarget(context)))
    throw Object.assign(new Error("The checkout changed while preparing to publish. Try again."), {
      statusCode: 409,
    })
  return { target, workingTree: status.stdout.trim() ? "changed" : "clean", remember }
}
