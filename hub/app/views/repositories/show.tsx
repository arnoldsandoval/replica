import { useSelector } from "react-redux"

import type { AppState } from "@application/store"
import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { RepositoriesShowPage } from "@pages/repositories-show-page"
import type { RepositoriesShowPageData } from "@pages/repositories-show-page/types"

export default function RepositoriesShowView() {
  const data = useRepositoryInbox(usePageData<RepositoriesShowPageData>())
  const managingPrototypes = useSelector(
    (state: AppState) => state.navigationRequest.path === data.managePrototypesPath,
  )

  return <RepositoriesShowPage data={data} managingPrototypes={managingPrototypes} />
}
