import { useCallback } from "react"
import { z } from "zod"

import type { HubAdministratorSearchResults } from "@features/add-hub-administrators/types"
import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { HubAdminsPage } from "@pages/hub-admins-page"
import type { HubAdminsPageData } from "@pages/hub-admins-page/types"

export default function HubAdminsIndexView() {
  const data = useWorkspaceInbox(usePageData<HubAdminsPageData>())
  const path = data.addAdministrator?.searchPath
  const onSearch = useCallback(
    async (query: string): Promise<HubAdministratorSearchResults> => {
      if (!path) throw new Error("Administrator access is unavailable")

      const url = new URL(path, window.location.origin)
      url.searchParams.set("query", query)
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (!response.ok) throw new Error("Hub user search failed")

      return z
        .object({
          users: z.array(
            z.object({
              id: z.number().int().positive(),
              login: z.string(),
              name: z.string().nullable(),
            }),
          ),
          more: z.boolean(),
        })
        .parse(await response.json())
    },
    [path],
  )
  return <HubAdminsPage data={data} onSearch={onSearch} />
}
