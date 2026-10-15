import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { FreshAuthorizationPage } from "@pages/fresh-authorization-page"
import type { FreshAuthorizationPageData } from "@pages/fresh-authorization-page/types"

export default function FreshAuthorizationsShowView() {
  return (
    <FreshAuthorizationPage data={useWorkspaceInbox(usePageData<FreshAuthorizationPageData>())} />
  )
}
