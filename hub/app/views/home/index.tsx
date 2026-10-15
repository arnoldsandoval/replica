import { useHubTheme } from "@hooks/use-hub-theme"
import { usePageData } from "@hooks/use-page-data"
import { HomeIndexPage } from "@pages/home-index-page"
import type { HomeIndexPageData } from "@pages/home-index-page/types"

export default function HomeIndexView() {
  const { resolvedColorMode } = useHubTheme()

  return <HomeIndexPage colorMode={resolvedColorMode} data={usePageData<HomeIndexPageData>()} />
}
