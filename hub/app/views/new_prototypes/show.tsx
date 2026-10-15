import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { NewPrototypePage } from "@pages/new-prototype-page"
import type { NewPrototypePageData } from "@pages/new-prototype-page/types"

export default function NewPrototypesShowView() {
  return <NewPrototypePage data={useRepositoryInbox(usePageData<NewPrototypePageData>())} />
}
