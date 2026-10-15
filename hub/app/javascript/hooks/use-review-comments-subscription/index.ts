import { createConsumer } from "@rails/actioncable"
import { useEffect, useRef } from "react"
import { z } from "zod"

import type { ReviewCommentsSubscriptionOptions } from "./types"

const cableConsumer = createConsumer()
const REVIEW_COMMENTS_INVALIDATION_SCHEMA = z
  .object({ type: z.literal("review_comments_changed") })
  .strict()

/** Requests an HTTP refresh after each valid notice or reconnection. */
export function useReviewCommentsSubscription({
  repositoryId,
  prototypeId,
  onInvalidation,
}: ReviewCommentsSubscriptionOptions) {
  const onInvalidationRef = useRef(onInvalidation)

  useEffect(() => {
    onInvalidationRef.current = onInvalidation
  }, [onInvalidation])

  useEffect(() => {
    const subscription = cableConsumer.subscriptions.create(
      {
        channel: "ReviewCommentsChannel",
        repositoryId,
        prototypeId,
      },
      {
        connected() {
          onInvalidationRef.current()
        },
        received(message: unknown) {
          if (REVIEW_COMMENTS_INVALIDATION_SCHEMA.safeParse(message).success) {
            onInvalidationRef.current()
          }
        },
        rejected() {
          onInvalidationRef.current()
        },
      },
    )

    return () => {
      subscription.unsubscribe()
    }
  }, [prototypeId, repositoryId])
}
