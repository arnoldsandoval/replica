import { fireEvent, render, screen } from "@testing-library/react"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"

import { replicaBrowseData } from "@/storybook/fixtures/replica-browse"
import type { ReviewRoute } from "@utils/review-anchor/types"

import ReplicaBrowsesShowView from "../../../views/replica_browses/show"

const state = vi.hoisted(() => ({ data: {} }))

vi.mock("@hooks/use-page-data", () => ({
  usePageData: () => state.data,
}))
vi.mock("@hooks/use-hub-theme", () => ({
  useHubTheme: () => ({ resolvedColorMode: "light" }),
  useOptionalHubTheme: () => null,
}))
vi.mock("@hooks/use-preview-bridge", () => ({
  usePreviewBridge: function useBridge() {
    const [route, setRoute] = useState<ReviewRoute | null>(null)
    return {
      route,
      handleFrameLoad: () => setRoute({ pathname: "/old-page", search: "?old=1", hash: "#old" }),
    }
  },
}))
vi.mock("@pages/replica-browse-page", () => ({
  ReplicaBrowsePage: ({
    route,
    onFrameLoad,
  }: {
    route: ReviewRoute | null
    onFrameLoad: () => void
  }) => <button onClick={onFrameLoad}>{route?.pathname ?? "Initial route"}</button>,
}))

describe("ReplicaBrowsesShowView()", () => {
  it("resets bridge state when switching templates even if their preview URLs match", () => {
    state.data = { ...replicaBrowseData, templateId: "welcome" }
    const page = render(<ReplicaBrowsesShowView />)
    fireEvent.click(screen.getByRole("button", { name: "Initial route" }))
    expect(screen.getByRole("button", { name: "/old-page" })).toBeInTheDocument()
    state.data = { ...replicaBrowseData, templateId: "field-notes" }
    page.rerender(<ReplicaBrowsesShowView />)
    expect(screen.getByRole("button", { name: "Initial route" })).toBeInTheDocument()
  })
})
