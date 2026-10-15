import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import prototypeStories from "@pages/prototypes-show-page/stories"
import type { PrototypesShowPageData } from "@pages/prototypes-show-page/types"
import inboxStories from "@pages/notifications-page/stories"
import { repliedReviewThread } from "@/storybook/fixtures/review/comments"
import type { ReviewThread } from "@utils/review-comment/types"

import PrototypesShowView from "../../views/prototypes/show"

let data: PrototypesShowPageData

vi.mock("@hooks/use-page-data", () => ({ usePageData: () => data }))
vi.mock("@hooks/use-hub-theme", () => ({
  useHubTheme: () => ({ resolvedColorMode: "light" }),
  useOptionalHubTheme: () => null,
}))
vi.mock("@hooks/use-prototype-viewer-url", () => ({
  usePrototypeViewerUrl: () => ({ viewerUrl: "/preview", minimized: false, setMinimized: vi.fn() }),
}))
vi.mock("@hooks/use-prototype-review", async () => {
  const { useState } = await import("react")
  return {
    usePrototypeReview: () => {
      const [selectedThread, selectThread] = useState<ReviewThread | null>(null)
      return {
        ...prototypeStories.args.review,
        threads: [repliedReviewThread],
        selectedThread,
        selectThread,
      }
    },
  }
})
afterEach(() => vi.unstubAllGlobals())

describe("PrototypesShowView() notification navigation", () => {
  it.each(["root", "reply"])(
    "focuses the exact %s before acknowledging its notification",
    async (kind) => {
      const message = kind === "root" ? repliedReviewThread.root : repliedReviewThread.replies[0]
      if (!message) throw new Error("Expected a reply fixture")

      data = {
        ...prototypeStories.args.data,
        initialCommentId: message.id,
        initialNotificationId: 7,
      }
      const fetch = vi.fn().mockImplementation((path: string) => {
        const target = document.querySelector(`[data-review-message-id="${message.id}"]`)
        expect(target).toHaveFocus()
        expect(target).toHaveAttribute("data-notification-target", "true")
        expect(path).toBe("/notifications/7")
        return Promise.resolve(
          Response.json({ commentId: message.id, version: 3, read: true, unreadCount: 0 }),
        )
      })
      vi.stubGlobal("fetch", fetch)
      render(<PrototypesShowView />)
      await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
      expect(fetch).toHaveBeenLastCalledWith("/notifications/7", {
        method: "PATCH",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": data.authenticityToken },
        body: JSON.stringify({ notification: { read: true, version: 3 } }),
      })
    },
  )

  it("does not acknowledge an unavailable source message", async () => {
    data = { ...prototypeStories.args.data, initialCommentId: 999999, initialNotificationId: 7 }
    const fetch = vi.fn()
    vi.stubGlobal("fetch", fetch)
    render(<PrototypesShowView />)
    await screen.findByText(data.reviewComments.copy.readErrorLabel)
    expect(fetch).not.toHaveBeenCalled()
  })

  it("opens a first-visit deep link without the description dialog covering its message", async () => {
    data = {
      ...prototypeStories.args.data,
      showPrototypeInfo: true,
      initialCommentId: repliedReviewThread.root.id,
      initialNotificationId: 7,
    }
    const fetch = vi.fn().mockImplementation(() => {
      expect(screen.queryByRole("dialog", { name: data.prototypeName })).not.toBeInTheDocument()
      return Promise.resolve(
        Response.json({
          commentId: repliedReviewThread.root.id,
          version: 3,
          read: true,
          unreadCount: 0,
        }),
      )
    })
    vi.stubGlobal("fetch", fetch)
    render(<PrototypesShowView />)
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
    expect(
      document.querySelector(`[data-review-message-id="${repliedReviewThread.root.id}"]`),
    ).toHaveFocus()
    expect(screen.queryByRole("dialog", { name: data.prototypeName })).not.toBeInTheDocument()
  })

  it("preserves the description dialog on ordinary first visits", () => {
    data = { ...prototypeStories.args.data, showPrototypeInfo: true }
    const fetch = vi.fn()
    vi.stubGlobal("fetch", fetch)
    render(<PrototypesShowView />)
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(fetch).not.toHaveBeenCalled()
  })

  it("updates the sidebar count and loaded preview after acknowledging the last unread item", async () => {
    const message = repliedReviewThread.root
    data = {
      ...prototypeStories.args.data,
      initialCommentId: message.id,
      initialNotificationId: 7,
      notificationInbox: inboxStories.args.data.notificationInbox,
      notificationsPath: "/notifications",
      notificationsLabel: "Inbox",
      notificationsUnreadCount: 1,
    }
    function unexpectedAcknowledgement() {
      throw new Error("Expected a pending acknowledgement")
    }
    let acknowledge: (response: Response) => void = unexpectedAcknowledgement
    const saved = new Promise<Response>((resolve) => {
      acknowledge = resolve
    })
    const fetch = vi.fn().mockImplementation((path: string | URL, options?: RequestInit) => {
      if (options?.method === "PATCH") return saved
      if (String(path).includes("/notifications/inbox")) {
        return Promise.resolve(
          Response.json({
            notifications: [
              {
                ...inboxStories.args.notifications[0],
                id: 7,
                version: 3,
                read: false,
                updatePath: "/notifications/7",
              },
            ],
            nextBefore: null,
            unreadCount: 1,
          }),
        )
      }
      return Promise.resolve(Response.json({ commentId: message.id, version: 3 }))
    })
    vi.stubGlobal("fetch", fetch)
    render(<PrototypesShowView />)
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
    const inbox = screen.getByRole("link", { name: "Inbox, 1 unread items" })
    fireEvent.mouseEnter(inbox)
    await screen.findByRole("button", { name: /^Mark as read:/ })
    await act(async () => {
      acknowledge(Response.json({ version: 4, read: true, unreadCount: 0 }))
      await saved
    })
    expect(screen.getByRole("link", { name: "Inbox" })).not.toHaveTextContent("1")
    expect(screen.getByText("You are all caught up")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /^Mark as unread:/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /^Mark as read:/ })).not.toBeInTheDocument()
  })

  it.each([
    { version: 4, read: false, unreadCount: 0 },
    { version: 4, read: true },
  ])("reports an invalid acknowledgement instead of applying it: %j", async (saved) => {
    data = {
      ...prototypeStories.args.data,
      initialCommentId: repliedReviewThread.root.id,
      initialNotificationId: 7,
    }
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockImplementation((_path: string, options?: RequestInit) =>
          Promise.resolve(
            Response.json(
              options?.method === "PATCH"
                ? saved
                : { commentId: repliedReviewThread.root.id, version: 3 },
            ),
          ),
        ),
    )
    render(<PrototypesShowView />)
    await screen.findByText(data.reviewComments.copy.readErrorLabel)
  })
})
