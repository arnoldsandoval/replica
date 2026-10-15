import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { WelcomePage } from "@pages/welcome-page"
import type { WelcomePageData } from "@pages/welcome-page/types"

export default function WelcomeShowView() {
  return <WelcomePage data={useWorkspaceInbox(usePageData<WelcomePageData>())} />
}
