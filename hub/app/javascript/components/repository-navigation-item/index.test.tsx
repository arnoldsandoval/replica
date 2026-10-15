import { configureStore } from "@reduxjs/toolkit"
import { fireEvent, render, screen } from "@testing-library/react"
import { rootReducer, setup, type ApplicationVisit } from "@thoughtbot/superglue"
import { describe, expect, it, vi } from "vitest"

import { GitBranchIcon, SidebarExpandIcon } from "@primer/octicons-react"

import { RepositoryNavigationItem } from "."

describe("RepositoryNavigationItem()", () => {
  it("keeps the selected repository destination as a link", () => {
    render(
      <RepositoryNavigationItem
        href="/repositories/2001"
        icon={GitBranchIcon}
        label="Prototypes"
        selected
      />,
    )

    const link = screen.getByRole("link", { name: "Prototypes" })
    expect(link).toHaveAttribute("href", "/repositories/2001")
    expect(link).toHaveAttribute("data-sg-visit", "true")
    expect(link).toHaveAttribute("aria-current", "page")
  })

  it.each([
    { name: "ordinary", event: {}, intercepted: true },
    { name: "Command", event: { metaKey: true }, intercepted: false },
    { name: "Control", event: { ctrlKey: true }, intercepted: false },
    { name: "Shift", event: { shiftKey: true }, intercepted: false },
    { name: "Alt", event: { altKey: true }, intercepted: false },
    { name: "middle button", event: { button: 1 }, intercepted: false },
  ])("uses existing Superglue delegation for $name clicks", ({ event, intercepted }) => {
    const visit = vi.fn<ApplicationVisit>().mockResolvedValue(undefined)
    const { ujs } = setup({
      baseUrl: window.location.origin,
      path: "/",
      initialPage: {
        componentIdentifier: "sidebar-test",
        data: {},
        assets: [],
        fragments: [],
        defers: [],
        slices: {},
        renderedAt: 0,
        restoreStrategy: "revisitOnly",
      },
      store: configureStore({ reducer: rootReducer }),
      navigatorRef: { current: null },
      buildVisitAndRemote: () => ({
        visit,
        remote: vi.fn(),
      }),
    })
    render(
      <div onClick={ujs.onClick}>
        <RepositoryNavigationItem
          href="/repositories/2001"
          icon={GitBranchIcon}
          label="Prototypes"
        />
      </div>,
    )
    const link = screen.getByRole("link", { name: "Prototypes" })
    const label = screen.getByText("Prototypes")
    const click = new MouseEvent("click", { bubbles: true, cancelable: true, ...event })

    fireEvent(label, click)

    expect(click.defaultPrevented).toBe(intercepted)
    if (intercepted) {
      expect(visit).toHaveBeenCalledExactlyOnceWith("/repositories/2001", {
        method: "GET",
        dataset: { sgVisit: "true" },
      })
    } else {
      expect(visit).not.toHaveBeenCalled()
    }
    expect(link).toHaveAttribute("href", "/repositories/2001")
    expect(link).not.toHaveAttribute("role")
    expect(link).not.toHaveAttribute("tabindex")
  })

  it("uses the same row as a labelled collapse button", () => {
    const onClick = vi.fn()
    render(
      <RepositoryNavigationItem
        icon={SidebarExpandIcon}
        label="Collapse sidebar"
        expanded
        onClick={onClick}
      />,
    )

    const button = screen.getByRole("button", { name: "Collapse sidebar" })
    expect(button).toHaveAttribute("aria-expanded", "true")
    expect(button).not.toHaveAttribute("data-sg-visit")
    fireEvent.click(button)
    expect(onClick).toHaveBeenCalledOnce()
  })
})
