import { CheckIcon, RepoIcon } from "@primer/octicons-react"
import { ActionMenu } from "@primer/react-brand"

import "./styles.css"

export interface RepositorySelectorRepository {
  id: string
  nameWithOwner: string
  path: string
}

/** Switches between repositories already available in Replica Hub. */
export function RepositorySelector({
  ariaLabel,
  collapsed = false,
  menuLabel,
  repositories,
  selectedRepositoryId,
}: {
  ariaLabel: string
  collapsed?: boolean
  menuLabel: string
  repositories: RepositorySelectorRepository[]
  selectedRepositoryId: string
}) {
  const selectedRepository = repositories.find(
    (repository) => repository.id === selectedRepositoryId,
  )

  return (
    <div className={`repository-selector${collapsed ? " repository-selector--collapsed" : ""}`}>
      <ActionMenu size="small" selectionVariant="none" menuAlignment="start">
        <ActionMenu.Button
          className="repository-selector__trigger"
          variant="secondary"
          size="small"
          aria-label={ariaLabel}
          leadingVisual={<RepoIcon size={16} />}
        >
          {collapsed ? (
            <span className="repository-selector__sr-only">{ariaLabel}</span>
          ) : (
            <span className="repository-selector__name">{selectedRepository?.nameWithOwner}</span>
          )}
        </ActionMenu.Button>
        <ActionMenu.Overlay aria-label={menuLabel} data-menu-label={menuLabel}>
          {repositories.map((repository) => (
            <ActionMenu.Item
              as="a"
              key={repository.id}
              href={repository.path}
              aria-current={repository.id === selectedRepositoryId ? "page" : undefined}
              leadingVisual={
                repository.id === selectedRepositoryId ? (
                  <CheckIcon size={16} />
                ) : (
                  <RepoIcon size={16} />
                )
              }
              onKeyDown={(event) => {
                if (
                  event.key === " " ||
                  (event.key === "Enter" && event.target === event.currentTarget)
                ) {
                  event.preventDefault()
                  event.currentTarget.querySelector("a")?.click()
                }
              }}
            >
              {repository.nameWithOwner}
            </ActionMenu.Item>
          ))}
        </ActionMenu.Overlay>
      </ActionMenu>
    </div>
  )
}
