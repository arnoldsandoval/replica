import type { Page } from "@thoughtbot/superglue"

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean

  interface Window {
    SUPERGLUE_INITIAL_PAGE_STATE: Page
  }
}

export {}
