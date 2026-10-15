import path from "node:path"

import { readRepositoryName } from "../read-repository-name/index.mjs"

export async function readCanvasRepository(context) {
  const repository = await readRepositoryName(context.repositoryPath)
  const localRoot = path.dirname(context.repositoryPath)
  const localName = path.basename(context.repositoryPath)
  const local =
    context.target?.repository === `local/${localName}` &&
    path.basename(localRoot) === "prototypes" &&
    path.basename(path.dirname(localRoot)) === ".local"

  return {
    repository: local ? context.target.repository : repository.repository,
    githubRepository: repository.repository,
    legacyRepository: repository.legacyRepository,
    local,
  }
}
