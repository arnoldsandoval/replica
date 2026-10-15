import { usePageData } from "@hooks/use-page-data"
import { HubAdminEnrollmentPage } from "@pages/hub-admin-enrollment-page"
import type { HubAdminEnrollmentPageData } from "@pages/hub-admin-enrollment-page/types"

export default function HubAdminEnrollmentsShowView() {
  return <HubAdminEnrollmentPage data={usePageData<HubAdminEnrollmentPageData>()} />
}
