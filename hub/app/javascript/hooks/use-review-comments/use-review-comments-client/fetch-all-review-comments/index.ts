import { REVIEW_COMMENT_PAGE_SCHEMA } from "@utils/review-comment/schemas"
import type { ReviewComment } from "@utils/review-comment/types"

import { REVIEW_COMMENTS_PAGE_SIZE } from "../../constants"
import { reviewAccessUnavailable } from "../review-access-unavailable"
import type { ReviewCommentsFetchResult } from "./types"

/** Fetches every cursor page without exposing a partial response. */
export async function fetchAllReviewComments(
  path: string,
  signal: AbortSignal,
): Promise<ReviewCommentsFetchResult> {
  const fetched: ReviewComment[] = []
  let cursor: string | null = null

  try {
    do {
      const url = new URL(path, window.location.origin)
      url.searchParams.set("pageSize", REVIEW_COMMENTS_PAGE_SIZE.toString())
      if (cursor) url.searchParams.set("cursor", cursor)

      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal,
      })
      if (reviewAccessUnavailable(response)) return { kind: "access-lost" }
      if (!response.ok) return { kind: "failed" }

      const parsedPage = REVIEW_COMMENT_PAGE_SCHEMA.safeParse(await response.json())
      if (!parsedPage.success) return { kind: "failed" }

      fetched.push(...parsedPage.data.comments)
      cursor = parsedPage.data.nextCursor
    } while (cursor)

    return { kind: "success", comments: fetched }
  } catch (error) {
    if (signal.aborted) throw error

    return { kind: "failed" }
  }
}
