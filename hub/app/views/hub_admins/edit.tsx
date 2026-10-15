import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { HubAdminConfirmationPage } from "@pages/hub-admin-confirmation-page"
import type { HubAdminConfirmationPageData } from "@pages/hub-admin-confirmation-page/types"

export default function HubAdminsEditView() {
  return (
    <HubAdminConfirmationPage
      data={useWorkspaceInbox(usePageData<HubAdminConfirmationPageData>())}
    />
  )
}
