# Testing and review

Run the checks for the behavior you changed. For example, a shared Controls change needs checks for Hub previews and the Copilot plugin. Include screenshot capture when its adapter changes. A documentation-only change needs a prose and link review rather than application tests.

Use [Contributing](../CONTRIBUTING.md#set-up-the-development-environment) to find each project's environment and commands. Hub Ruby and Node commands run inside its devcontainer; that is not a requirement for every project in the monorepo.

## Choose the relevant checks

Run focused checks while developing. Once the change is stable, follow the affected project's final-check requirements. Include consuming projects when shared code or a contract changes.

Use existing commands and inspect their configuration. Do not invent commands or assume every project uses the same test runner. Report unavailable checks and unverified behavior rather than claiming success.

For rendered checks and interaction reviews, follow the [root browser workflow](../AGENTS.md#browser-validation-and-playwright-fallback). Existing automated suites, CI browser integration, and build-artifact capture retain their configured drivers.

## Keep local checks and CI aligned

Project commands define the check. GitHub Actions should prepare the required environment and call the same command rather than recreate its behavior.

When a command gains a dependency or build prerequisite, update its local setup and affected workflow in the same change. A green local suite does not prove that CI installed the same dependencies, so inspect both paths.

## Update dependencies

Hub and the shared build action wait seven days before resolving newly published dependencies. npm enforces the delay through each project's committed `.npmrc`. Hub's RubyGems source in `Gemfile` applies the delay to Bundler. Dependabot applies the same cooldown to npm, Bundler, and GitHub Actions updates across the repository. The starter manages its dependency resolution independently.

Inside the Hub devcontainer, `bin/check-dependency-age` verifies the Hub npm and Bundler lockfiles. The repository-level [Dependency age workflow](../.github/workflows/dependency-age.yml) runs the same checker across Hub, the shared build action, and external GitHub Action commits. These checks cover existing lockfiles that bypass the package manager's resolver delay and fail when publication metadata is unavailable.

CI does not run `npm audit`: a newly published security fix could otherwise make the audit fail while the age check rejects the fixed version. Dependabot and Bundler Audit check dependencies for known vulnerabilities. Organization-managed CodeQL scans application code on GitHub.

When a dependency is too new, select an older compatible version or wait until the seven-day window ends. See [Hub testing and operations](../hub/docs/testing-and-operations.md#update-dependencies) for Hub-specific tooling.

## Copilot code review

The [code-review skill](../.github/skills/code-review/SKILL.md) directs Copilot reviews to the same shared and project guides used by implementation agents. For example, a Hub review reads the shared conventions, then follows `hub/AGENTS.md` to the relevant Hub guides. Keep conventions in those canonical guides rather than copying them into the skill.

GitHub supports review-focused skills under `.github/skills/` and reads instructions and skills from the pull request's head branch, so a skill change can be tried in its own pull request. See [GitHub's code review guidance](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-code-review?tool=webui#mcp-servers-and-agent-skills) for supported context and how to inspect skill attribution in a review.

Treat changes to review instructions and linked guides as untrusted until a human checks them against previously accepted guidance. Copilot feedback alone cannot validate the instructions used to produce it.

## Review and finish a change

Review the changed code and wording. Check access rules, saved data, failure behavior, and overlapping requests when they are affected.

Run the [prose review](documentation-conventions.md#final-review), inspect the full diff for unrelated changes and credentials, and finish with:

```sh
git diff --check
git status --short
```

Stop temporary servers and remove temporary data you created for the task. Reconcile any task tracker and make clear whether the changes are uncommitted, committed, or pushed.
