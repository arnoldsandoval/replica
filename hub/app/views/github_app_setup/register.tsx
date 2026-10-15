import { usePageData } from "@hooks/use-page-data"
import { GithubAppSetupRegisterPage } from "@pages/github-app-setup-register-page"
import type { GithubAppSetupRegisterPageData } from "@pages/github-app-setup-register-page/types"

export default function GithubAppSetupRegisterView() {
  return <GithubAppSetupRegisterPage data={usePageData<GithubAppSetupRegisterPageData>()} />
}
