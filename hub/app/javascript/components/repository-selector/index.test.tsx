import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { RepositorySelector } from "."

const data = {
  ariaLabel: "Choose repository. github/prototype selected",
  menuLabel: "Repositories",
  repositories: [
    { id: "2001", nameWithOwner: "github/prototype", path: "/repositories/2001" },
    { id: "2002", nameWithOwner: "github/empty", path: "/repositories/2002" },
  ],
  selectedRepositoryId: "2001",
}

describe("RepositorySelector()", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "ResizeObserver",
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
    )
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("shows the selected repository and keeps its menu links", async () => {
    render(<RepositorySelector {...data} />)

    const trigger = screen.getByRole("button", { name: data.ariaLabel })
    expect(trigger).toHaveTextContent("github/prototype")
    expect(trigger.className).toContain("Button--size-small")
    expect(trigger.className).toContain("Button--secondary")
    fireEvent.click(trigger)
    expect(screen.getByRole("menu", { name: data.menuLabel })).toHaveAttribute(
      "data-menu-label",
      data.menuLabel,
    )
    expect(screen.getByRole("menuitem", { name: "github/prototype" })).toHaveAttribute(
      "aria-current",
      "page",
    )
    await waitFor(() =>
      expect(screen.getByRole("menuitem", { name: "github/prototype" })).toHaveFocus(),
    )
    expect(screen.getByRole("link", { name: "github/empty" })).toHaveAttribute(
      "href",
      "/repositories/2002",
    )
  })

  it("keeps the repository menu labelled when collapsed", () => {
    render(<RepositorySelector {...data} collapsed />)

    const trigger = screen.getByRole("button", { name: data.ariaLabel })
    expect(trigger.querySelector(".repository-selector__name")).toBeNull()
    fireEvent.click(trigger)
    expect(screen.getByRole("menuitem", { name: "github/empty" })).toBeInTheDocument()
  })

  it.each(["Enter", " "])("activates a repository link with %s", (key) => {
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {})
    render(<RepositorySelector {...data} />)

    fireEvent.click(screen.getByRole("button", { name: data.ariaLabel }))
    fireEvent.keyDown(screen.getByRole("menuitem", { name: "github/empty" }), { key })
    expect(click).toHaveBeenCalledOnce()
    expect(click.mock.instances[0]).toHaveAttribute("href", "/repositories/2002")
  })
})
