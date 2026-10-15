import { usePageData } from "@hooks/use-page-data"
import { GithubAppSetupShowPage } from "@pages/github-app-setup-show-page"
import type { GithubAppSetupShowPageData } from "@pages/github-app-setup-show-page/types"

export default function GithubAppSetupShowView() {
  return <GithubAppSetupShowPage data={usePageData<GithubAppSetupShowPageData>()} />
}
