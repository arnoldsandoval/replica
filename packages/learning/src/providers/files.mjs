import { constants, lstatSync, realpathSync } from "node:fs"
import path from "node:path"
import { LearningError } from "../errors.mjs"

/** The open flag that refuses a link as the last part of a path, where the platform has one. */
export const NO_FOLLOW = constants.O_NOFOLLOW ?? 0

/**
 * Refuse a path that a provider keeps in its data directory, root, unless it is the provider's
 * own: a regular file, or a directory where one is expected, that is not a link, has no second
 * name, and resolves to the same place inside the real root. Anyone who can write the data
 * directory, such as a coding agent in the checkout, could otherwise point a store file at a
 * file elsewhere, and every read and write would reach that file.
 *
 * @param {string} root
 * @param {string} target a path inside root
 * @param {import("node:fs").Stats} info lstat of target, or fstat of the file opened there
 * @param {{ directory?: boolean }} [options]
 */
export function assertOwnPath(root, target, info, { directory = false } = {}) {
  let problem = null
  if (info.isSymbolicLink()) problem = "is a symbolic link"
  else if (directory ? !info.isDirectory() : !info.isFile())
    problem = `is not a ${directory ? "directory" : "regular file"}`
  else if (!directory && info.nlink > 1) problem = "has a second name, a hard link"
  else {
    let real
    try {
      real = realpathSync(target)
    } catch (error) {
      // SQLite removes its log files when the last connection closes, so a file found a moment
      // ago may be gone. A path that is gone leads nowhere.
      if (error.code === "ENOENT") return
      throw error
    }
    if (real !== path.join(realpathSync(root), path.relative(root, target)))
      problem = `resolves to ${real}`
  }
  if (problem) throw ownPathError(root, target, problem)
}

/**
 * Refuse a path unless it still names the file a provider checked before opening it by name:
 * it must be the provider's own, as assertOwnPath says, on the same device and with the same
 * inode. A library that opens a path itself and follows links, as node:sqlite does, then has
 * the file that was checked, unless another process swaps the path between the checks.
 *
 * @param {string} root
 * @param {string} target a path inside root
 * @param {import("node:fs").Stats} checked what the earlier check found at target
 */
export function assertSameFile(root, target, checked) {
  const info = lstatSync(target, { throwIfNoEntry: false })
  if (!info) throw ownPathError(root, target, "was removed after it was checked")
  assertOwnPath(root, target, info)
  if (info.dev !== checked.dev || info.ino !== checked.ino)
    throw ownPathError(root, target, "was replaced after it was checked")
}

/** The error to report for an open that refused a link: ELOOP, or EMLINK on some systems. */
export function openError(root, target, error) {
  return error?.code === "ELOOP" || error?.code === "EMLINK"
    ? ownPathError(root, target, "is a symbolic link")
    : error
}

function ownPathError(root, target, problem) {
  return new LearningError(
    "storage_corrupt",
    `${target} ${problem}. A store uses only its own files in ${root}, so remove it.`,
  )
}
