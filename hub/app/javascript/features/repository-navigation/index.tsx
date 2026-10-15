import type { MouseEventHandler, ReactNode } from "react"

import { WorkspaceSidebar } from "@features/workspace-sidebar"

import type { RepositoryNavigationData } from "./types"

/** Uses the shared sidebar without changing the existing repository projection. */
export function RepositoryNavigation({
  collapsed,
  data,
  inboxPreview,
  onInboxClick,
  onCollapsedChange,
}: {
  collapsed: boolean
  data: RepositoryNavigationData
  inboxPreview?: (close: () => void) => ReactNode
  onInboxClick?: MouseEventHandler<HTMLAnchorElement>
  onCollapsedChange: (collapsed: boolean) => void
}) {
  return (
    <WorkspaceSidebar
      collapsed={collapsed}
      data={{ ...data, repository: data }}
      inboxPreview={inboxPreview}
      onInboxClick={onInboxClick}
      onCollapsedChange={onCollapsedChange}
    />
  )
}
