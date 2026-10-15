import { useContent } from "@thoughtbot/superglue"

/** Gives a page a typed view over its server-rendered props. */
export function usePageData<PageData>(): PageData {
  return useContent<PageData>()
}
