import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { BuildsShowPage } from "@pages/builds-show-page"
import type { BuildsShowPageData } from "@pages/builds-show-page/types"

export default function BuildsShowView() {
  return <BuildsShowPage data={useRepositoryInbox(usePageData<BuildsShowPageData>())} />
}
