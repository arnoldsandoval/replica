import type {
  ApplicationRemote,
  ApplicationVisit,
  BuildVisitAndRemote,
  SuperglueStore,
} from "@thoughtbot/superglue"
import { remote, visit } from "@thoughtbot/superglue/action_creators"

import { navigationRequest } from "@application/navigation-request"

let nextVisitRequestId = 0

/** Connects Superglue navigation to browser history and full-page fallbacks. */
export const buildVisitAndRemote: BuildVisitAndRemote = (ref, store: SuperglueStore) => {
  const appRemote: ApplicationRemote = (path, options) => {
    const requestOptions = { ...options }
    delete requestOptions.dataset
    return store.dispatch(remote(path, requestOptions))
  }

  const appVisit: ApplicationVisit = (path, { dataset, ...options } = {}) => {
    const requestId = ++nextVisitRequestId
    store.dispatch(navigationRequest.actions.started({ id: requestId, path: String(path) }))

    return store
      .dispatch(visit(path, options))
      .then((metadata) => {
        if (metadata.needsRefresh) {
          window.location.href = metadata.pageKey
          return metadata
        }

        ref.current?.navigateTo(metadata.pageKey, {
          action: dataset?.sgReplace ? "replace" : metadata.navigationAction,
        })
        return metadata
      })
      .finally(() => {
        store.dispatch(navigationRequest.actions.finished({ id: requestId }))
      })
  }

  return { visit: appVisit, remote: appRemote }
}
