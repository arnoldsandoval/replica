import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { SharingSettingsPage } from "@pages/sharing-settings-page"
import type { SharingSettingsPageData } from "@pages/sharing-settings-page/types"

export default function SharingSettingsShowView() {
  return <SharingSettingsPage data={useWorkspaceInbox(usePageData<SharingSettingsPageData>())} />
}
