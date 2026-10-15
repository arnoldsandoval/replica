import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { AnalyticsPage } from "@pages/analytics-page"
import type { AnalyticsPageData } from "@pages/analytics-page/types"

/** Adapts authorized Rails page data without moving credentials into browser state. */
export default function AnalyticsShowView() {
  return <AnalyticsPage data={useRepositoryInbox(usePageData<AnalyticsPageData>())} />
}
