import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"

import { PrototypeManagementPage } from "@pages/prototype-management-page"
import type { PrototypeManagementPageData } from "@pages/prototype-management-page/types"

export default function PrototypeManagementShowView() {
  return (
    <PrototypeManagementPage
      data={useRepositoryInbox(usePageData<PrototypeManagementPageData>())}
    />
  )
}
