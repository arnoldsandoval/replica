import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { SessionRevocationPage } from "@pages/session-revocation-page"
import type { SessionRevocationPageData } from "@pages/session-revocation-page/types"

export default function SessionRevocationsShowView() {
  return (
    <SessionRevocationPage data={useWorkspaceInbox(usePageData<SessionRevocationPageData>())} />
  )
}
