import { runCommand } from "../run-command/index.mjs"

export async function readRepositoryName(repositoryPath) {
  const result = await runCommand("git", ["remote", "get-url", "origin"], repositoryPath)
  if (!result.ok) {
    return { repository: null, error: result.error }
  }

  const repository = parseGitHubRepository(result.stdout.trim())
  return repository
    ? { repository: repository.toLowerCase(), legacyRepository: repository, error: null }
    : {
        repository: null,
        error: "The origin remote is not a GitHub repository.",
      }
}

function parseGitHubRepository(remoteUrl) {
  const match = remoteUrl.match(
    /^(?:https?:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([^/\s]+)\/([^/\s]+?)(?:\.git)?$/,
  )
  return match && /^[a-z0-9-]+$/i.test(match[1]) && /^[a-z0-9_.-]+$/i.test(match[2])
    ? `${match[1]}/${match[2]}`
    : null
}
