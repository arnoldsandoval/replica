import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { ShareLinksIndexPage } from "@pages/share-links-index-page"
import type { ShareLinksIndexPageData } from "@pages/share-links-index-page/types"
import { useControlQuery } from "@hooks/use-prototype-control-query"
import { useShareControlSettings } from "@hooks/use-prototype-share-control-settings"

export default function ShareLinksIndexView() {
  const data = useRepositoryInbox(usePageData<ShareLinksIndexPageData>())
  const controls = useControlQuery()
  const settings = useShareControlSettings(data.controlSettingsIdentity, controls.values)
  return (
    <ShareLinksIndexPage
      data={data}
      sourceControlQuery={controls.query}
      controlSettings={{ ...settings, error: settings.error || controls.notice }}
    />
  )
}
