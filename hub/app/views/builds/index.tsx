import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { BuildsIndexPage } from "@pages/builds-index-page"
import type { BuildsIndexPageData } from "@pages/builds-index-page/types"

export default function BuildsIndexView() {
  return <BuildsIndexPage data={useRepositoryInbox(usePageData<BuildsIndexPageData>())} />
}
