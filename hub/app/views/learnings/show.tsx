import { usePageData } from "@hooks/use-page-data"
import { LearningsPage } from "@pages/learnings-page"
import type { LearningsPageData } from "@pages/learnings-page/types"

/** Adapts the repository's learnings, already filtered to what its administrators may see. */
export default function LearningsShowView() {
  return <LearningsPage data={usePageData<LearningsPageData>()} />
}
