import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { GithubAppPage } from "@pages/github-app-page"
import type { GithubAppPageData } from "@pages/github-app-page/types"

export default function GithubAppCredentialsEditView() {
  return <GithubAppPage data={useWorkspaceInbox(usePageData<GithubAppPageData>())} />
}
