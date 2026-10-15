import { act, renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { useReviewCommentsSubscription } from "."

interface SubscriptionCallbacks {
  connected: () => void
  received: (message: unknown) => void
  rejected: () => void
}

const CABLE = vi.hoisted(() => ({
  callbacks: null as SubscriptionCallbacks | null,
  identifier: null as Record<string, unknown> | null,
  unsubscribe: vi.fn(),
}))

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: (identifier: Record<string, unknown>, callbacks: SubscriptionCallbacks) => {
        CABLE.identifier = identifier
        CABLE.callbacks = callbacks
        return { unsubscribe: CABLE.unsubscribe }
      },
    },
  }),
}))

afterEach(() => {
  CABLE.callbacks = null
  CABLE.identifier = null
})

describe("useReviewCommentsSubscription()", () => {
  it("refreshes after connecting, valid invalidations, and rejected access", () => {
    const onInvalidation = vi.fn()
    const { unmount } = renderHook(() =>
      useReviewCommentsSubscription({
        repositoryId: 2001,
        prototypeId: 1,
        onInvalidation,
      }),
    )

    expect(CABLE.identifier).toEqual({
      channel: "ReviewCommentsChannel",
      repositoryId: 2001,
      prototypeId: 1,
    })

    act(() => CABLE.callbacks?.connected())
    act(() => CABLE.callbacks?.connected())
    act(() => CABLE.callbacks?.received({ type: "other_message" }))
    expect(onInvalidation).toHaveBeenCalledTimes(2)

    act(() => CABLE.callbacks?.received({ type: "review_comments_changed" }))
    act(() => CABLE.callbacks?.rejected())
    expect(onInvalidation).toHaveBeenCalledTimes(4)

    unmount()
    expect(CABLE.unsubscribe).toHaveBeenCalledOnce()
  })
})
