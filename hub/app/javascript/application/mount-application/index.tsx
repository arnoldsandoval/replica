import { Application } from "@thoughtbot/superglue"
import { createRoot } from "react-dom/client"

import { buildVisitAndRemote } from "@application/build-visit-and-remote"
import { pageIdentifierToPageComponent } from "@application/page-mapping"
import { store } from "@application/store"
import { HubThemeProvider } from "@hooks/use-hub-theme"

/** Mounts the server-provided Superglue page inside Hub's theme. */
export function mountApplication() {
  const element = document.getElementById("app")
  if (!element) return

  createRoot(element).render(
    <HubThemeProvider>
      <Application
        baseUrl={window.location.origin}
        initialPage={window.SUPERGLUE_INITIAL_PAGE_STATE}
        path={`${window.location.pathname}${window.location.search}${window.location.hash}`}
        buildVisitAndRemote={buildVisitAndRemote}
        store={store}
        mapping={pageIdentifierToPageComponent}
      />
    </HubThemeProvider>,
  )
}
