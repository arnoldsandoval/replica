import { act, renderHook } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"

import type { ReviewRoute } from "@utils/review-anchor/types"

import { usePrototypeViewerUrl } from "."

const selectedBuild = {
  number: 2,
  previewUrl: "http://b12.preview.replica.localhost:19500/copilot?tab=all#overview",
}

describe("usePrototypeViewerUrl()", () => {
  it("refreshes the copied viewer URL when controls change without losing its page destination", () => {
    window.history.replaceState(
      {},
      "",
      "/repositories/2001/prototypes/1?build=2&return_path=%2Fsettings",
    )
    const { result } = renderHook(() =>
      usePrototypeViewerUrl({ selectedBuild, route: null, initiallyMinimized: false }),
    )
    act(() => {
      const url = new URL(window.location.href)
      url.searchParams.set("rc.page.title", '"Configured"')
      window.history.replaceState(window.history.state, "", url)
      window.dispatchEvent(new Event("replica:controls:url"))
    })
    const url = new URL(result.current.viewerUrl)
    expect(url.searchParams.get("rc.page.title")).toBe('"Configured"')
    expect(url.searchParams.get("return_path")).toBe("/settings")
    expect(window.location.href).toBe(result.current.viewerUrl)
  })

  beforeEach(() => {
    window.history.replaceState(
      { superglue: "saved-page" },
      "",
      "/repositories/2001/prototypes/1?source=gallery",
    )
  })

  it("keeps the Hub address and history state while recording the exact Build and start page", () => {
    const { result } = renderHook(() =>
      usePrototypeViewerUrl({ selectedBuild, route: null, initiallyMinimized: false }),
    )
    const url = new URL(result.current.viewerUrl)
    expect(url.pathname).toBe("/repositories/2001/prototypes/1")
    expect(url.searchParams.get("source")).toBe("gallery")
    expect(url.searchParams.get("build")).toBe("2")
    expect(url.searchParams.get("return_path")).toBe("/copilot?tab=all#overview")
    expect(window.location.href).toBe(result.current.viewerUrl)
    expect(window.history.state).toEqual({ superglue: "saved-page" })
  })

  it("updates deep routes, queries and hash-based routes without adding Hub history entries", () => {
    const length = window.history.length
    const initialProps: { route: ReviewRoute | null } = { route: null }
    const { result, rerender } = renderHook(
      ({ route }: { route: ReviewRoute | null }) =>
        usePrototypeViewerUrl({ selectedBuild, route, initiallyMinimized: false }),
      { initialProps },
    )
    rerender({
      route: {
        pathname: "/copilot/task/123",
        search: "?filter=a%26b&next=%2Fsettings",
        hash: "#/details?tab=activity",
      },
    })
    expect(new URL(result.current.viewerUrl).searchParams.get("return_path")).toBe(
      "/copilot/task/123?filter=a%26b&next=%2Fsettings#/details?tab=activity",
    )
    expect(window.location.href).toBe(result.current.viewerUrl)
    expect(window.history.length).toBe(length)
  })

  it("shares minimized mode and removes only that mode when maximizing", () => {
    const { result } = renderHook(() =>
      usePrototypeViewerUrl({ selectedBuild, route: null, initiallyMinimized: true }),
    )
    expect(result.current.minimized).toBe(true)
    expect(new URL(window.location.href).searchParams.get("view")).toBe("minimized")

    act(() => result.current.setMinimized(false))
    expect(new URL(window.location.href).searchParams.has("view")).toBe(false)
    expect(new URL(window.location.href).searchParams.get("return_path")).toBe(
      "/copilot?tab=all#overview",
    )
    act(() => result.current.setMinimized(true))
    expect(new URL(window.location.href).searchParams.get("view")).toBe("minimized")
  })

  it("keeps the last page while the same iframe reloads but uses the next Build's start page", () => {
    const initialProps: {
      selectedBuild: typeof selectedBuild
      route: ReviewRoute | null
    } = {
      selectedBuild,
      route: { pathname: "/copilot/task/123", search: "?tab=activity", hash: "#details" },
    }
    const { result, rerender } = renderHook(
      (props: typeof initialProps) =>
        usePrototypeViewerUrl({ ...props, initiallyMinimized: false }),
      { initialProps },
    )
    const currentUrl = result.current.viewerUrl
    rerender({ selectedBuild, route: null })
    expect(result.current.viewerUrl).toBe(currentUrl)

    rerender({
      selectedBuild: { number: 3, previewUrl: "http://b13.preview.replica.localhost:19500/new" },
      route: null,
    })
    expect(new URL(result.current.viewerUrl).searchParams.get("return_path")).toBe("/new")
  })

  it("does not change the browser address without a successful Build", () => {
    const original = window.location.href
    const { result } = renderHook(() =>
      usePrototypeViewerUrl({ route: null, initiallyMinimized: true }),
    )
    expect(result.current.viewerUrl).toBe(original)
    expect(window.location.href).toBe(original)
    expect(result.current.minimized).toBe(false)
  })

  it("removes incoming Browse snapshot parameters even before a successful Build exists", () => {
    window.history.replaceState(
      { retained: true },
      "",
      "/repositories/1/replica?build=99&before=invalid&return_path=%2F%23%2Fabout&view=minimized",
    )
    const { result } = renderHook(() =>
      usePrototypeViewerUrl({ route: null, initiallyMinimized: true, pinBuild: false }),
    )
    const url = new URL(result.current.viewerUrl)
    expect(result.current.minimized).toBe(false)
    expect(url.searchParams.has("build")).toBe(false)
    expect(url.searchParams.has("before")).toBe(false)
    expect(url.searchParams.get("return_path")).toBe("/#/about")
    expect(url.searchParams.get("view")).toBe("minimized")
    expect(window.location.href).toBe(result.current.viewerUrl)
    expect(window.history.state).toEqual({ retained: true })
  })

  it("tracks Browse routes without retaining Build or history parameters", () => {
    window.history.replaceState(
      { retained: true },
      "",
      "/repositories/2001/replica?build=2&before=invalid&source=gallery#hub",
    )
    const initialProps: { route: ReviewRoute | null } = { route: null }
    const { result, rerender } = renderHook(
      ({ route }: typeof initialProps) =>
        usePrototypeViewerUrl({
          selectedBuild,
          route,
          initiallyMinimized: false,
          pinBuild: false,
        }),
      { initialProps },
    )
    rerender({ route: { pathname: "/about", search: "?tab=details", hash: "#team" } })
    const url = new URL(result.current.viewerUrl)
    expect(url.pathname).toBe("/repositories/2001/replica")
    expect(url.searchParams.has("build")).toBe(false)
    expect(url.searchParams.has("before")).toBe(false)
    expect(url.searchParams.get("return_path")).toBe("/about?tab=details#team")
    expect(url.searchParams.has("view")).toBe(false)
    expect(url.searchParams.get("source")).toBe("gallery")
    expect(url.hash).toBe("#hub")
    expect(window.history.state).toEqual({ retained: true })
    expect(window.location.href).toBe(result.current.viewerUrl)
  })

  it("shares unpinned minimized Browse links and preserves their exact route when maximizing", () => {
    const destination = "/#/about?tab=details"
    window.history.replaceState(
      { retained: true },
      "",
      `/repositories/1/replica?return_path=${encodeURIComponent(destination)}&view=minimized&build=99&before=invalid&filter=all#hub`,
    )
    const { result, rerender } = renderHook(
      ({ route }: { route: ReviewRoute | null }) =>
        usePrototypeViewerUrl({
          selectedBuild,
          route,
          initiallyMinimized: true,
          pinBuild: false,
        }),
      { initialProps: { route: null as ReviewRoute | null } },
    )
    expect(result.current.minimized).toBe(true)
    expect(new URL(result.current.viewerUrl).searchParams.get("return_path")).toBe(destination)
    act(() => result.current.setMinimized(false))
    expect(new URL(window.location.href).searchParams.has("view")).toBe(false)
    expect(new URL(window.location.href).searchParams.get("return_path")).toBe(destination)
    act(() => result.current.setMinimized(true))
    rerender({
      route: {
        pathname: "/settings",
        search: "?filter=a%26b&next=%2Fabout",
        hash: "#team",
      },
    })
    const url = new URL(result.current.viewerUrl)
    expect(url.searchParams.get("view")).toBe("minimized")
    expect(url.searchParams.get("return_path")).toBe("/settings?filter=a%26b&next=%2Fabout#team")
    expect(url.searchParams.has("build")).toBe(false)
    expect(url.searchParams.has("before")).toBe(false)
    expect(url.searchParams.get("filter")).toBe("all")
    expect(url.hash).toBe("#hub")
    expect(window.history.state).toEqual({ retained: true })
  })
})
