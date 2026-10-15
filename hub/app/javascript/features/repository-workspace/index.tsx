import type { MouseEventHandler, PropsWithChildren, ReactNode } from "react"

import { RepositoryNavigation } from "@features/repository-navigation"
import { WorkspaceFrame } from "@features/workspace-frame"

import type { RepositoryWorkspaceData } from "./types"

/** Frames repository pages with repository, section, and account navigation. */
export function RepositoryWorkspace({
  children,
  data,
  defaultNavigationCollapsed = false,
  inboxPreview,
  onInboxClick,
}: PropsWithChildren<{
  data: RepositoryWorkspaceData
  defaultNavigationCollapsed?: boolean
  inboxPreview?: (close: () => void) => ReactNode
  onInboxClick?: MouseEventHandler<HTMLAnchorElement>
}>) {
  return (
    <WorkspaceFrame
      defaultNavigationCollapsed={defaultNavigationCollapsed}
      navigation={(collapsed, onCollapsedChange) => (
        <RepositoryNavigation
          data={data}
          collapsed={collapsed}
          onCollapsedChange={onCollapsedChange}
          inboxPreview={inboxPreview}
          onInboxClick={onInboxClick}
        />
      )}
    >
      {children}
    </WorkspaceFrame>
  )
}
