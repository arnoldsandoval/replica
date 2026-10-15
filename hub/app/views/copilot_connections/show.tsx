import { usePageData } from "@hooks/use-page-data"
import { CopilotConnectionPage } from "@pages/copilot-connection-page"
import type { CopilotConnectionPageData } from "@pages/copilot-connection-page/types"

export default function CopilotConnectionsShowView() {
  return <CopilotConnectionPage data={usePageData<CopilotConnectionPageData>()} />
}
