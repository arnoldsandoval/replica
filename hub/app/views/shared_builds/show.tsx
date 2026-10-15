import { usePageData } from "@hooks/use-page-data"
import { SharedBuildsShowPage } from "@pages/shared-builds-show-page"
import type { SharedBuildsShowPageData } from "@pages/shared-builds-show-page/types"

export default function SharedBuildsShowView() {
  return <SharedBuildsShowPage data={usePageData<SharedBuildsShowPageData>()} />
}
