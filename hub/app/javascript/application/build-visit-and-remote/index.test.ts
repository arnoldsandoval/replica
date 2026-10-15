import type { SuperglueStore } from "@thoughtbot/superglue"
import { visit } from "@thoughtbot/superglue/action_creators"
import { describe, expect, it, vi } from "vitest"

import { navigationRequest } from "@application/navigation-request"

import { buildVisitAndRemote } from "."

vi.mock("@thoughtbot/superglue/action_creators", () => ({
  remote: vi.fn(),
  visit: vi.fn(),
}))

describe("buildVisitAndRemote()", () => {
  it.each([new Error("Network unavailable"), new DOMException("Visit cancelled", "AbortError")])(
    "clears a pending navigation after %s",
    async (failure) => {
      const visitAction = { type: "test/visit" }
      const dispatched: unknown[] = []
      vi.mocked(visit).mockReturnValue(visitAction as never)
      const store = {
        dispatch: vi.fn((action: unknown) => {
          dispatched.push(action)
          return action === visitAction ? Promise.reject(failure) : action
        }),
      } as unknown as SuperglueStore
      const application = buildVisitAndRemote({ current: null }, store)

      await expect(application.visit("/repositories/1/prototypes/manage", {})).rejects.toBe(failure)

      expect(dispatched.some(navigationRequest.actions.started.match)).toBe(true)
      expect(dispatched.some(navigationRequest.actions.finished.match)).toBe(true)
      const state = dispatched.reduce<ReturnType<typeof navigationRequest.getInitialState>>(
        (current, action) => navigationRequest.reducer(current, action as never),
        navigationRequest.getInitialState(),
      )
      expect(state.path).toBeNull()
    },
  )
})
