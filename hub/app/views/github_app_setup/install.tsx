import { usePageData } from "@hooks/use-page-data"
import { GithubAppSetupInstallPage } from "@pages/github-app-setup-install-page"
import type { GithubAppSetupInstallPageData } from "@pages/github-app-setup-install-page/types"

export default function GithubAppSetupInstallView() {
  return <GithubAppSetupInstallPage data={usePageData<GithubAppSetupInstallPageData>()} />
}
