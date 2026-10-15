import { useEffect, useState } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { App } from "."
import { publicationExamples } from "@utils/resolve-prototype-publication/fixtures"
import type { ShareLink } from "@hooks/use-canvas-share-links/types"
import type { HubStatus, PrototypeState, PublishPreparation } from "@utils/prototype-canvas/types"

import "./stories.css"

function PublicationDemo({
  scenario,
  prototypeUrl,
  withShareLinks = false,
}: {
  scenario: string
  prototypeUrl: string
  withShareLinks?: boolean
}) {
  const [ready, setReady] = useState(false)
  useEffect(() => {
    const fixture = publicationExamples[scenario]
    if (!fixture) throw new Error(`Unknown publication example: ${scenario}`)
    let state: PrototypeState | null = structuredClone(fixture.state)
    let hub: HubStatus | null = structuredClone(fixture.hub)
    let remember = false
    if (withShareLinks && hub?.prototype)
      hub.prototype = { ...hub.prototype, canManageShareLinks: true }
    let links: ShareLink[] = ["Usability review", "Design review"].map((label, index) => ({
      id: index + 1,
      label,
      buildNumber: 1,
      url: `https://hub.example.com/share/12345678-1234-1234-1234-${String(index + 1).padStart(12, "0")}`,
      expiresAt: null,
      createdAt: "2026-10-05T07:00:00Z",
      createdBy: { login: "octocat", name: "The Octocat" },
    }))
    let nextId = links.length + 1
    const originalFetch = window.fetch.bind(window)
    window.fetch = async (input, init) => {
      const path = typeof input === "string" ? input : input instanceof URL ? input.href : input.url
      if (!path.startsWith("/api/")) return originalFetch(input, init)
      let data: unknown
      if (path === "/api/state" || path === "/api/refresh") data = state
      else if (path === "/api/hub/status") data = hub
      else if (path === "/api/hub/open" || path === "/api/hub/activity") data = hub
      else if (path === "/api/hub/discovery") data = hub
      else if (
        path === "/api/publish/prepare" &&
        state?.stats.repository &&
        state.stats.branch &&
        state.stats.commitSha
      )
        data = {
          target: {
            repository: state.stats.repository,
            branch: state.stats.branch,
            commitSha: state.stats.commitSha,
            originFingerprint: null,
            pushFingerprint: null,
          },
          workingTree: state.stats.workingTree === "changed" ? "changed" : "clean",
          remember,
        } satisfies PublishPreparation
      else if (path === "/api/publish/preference") {
        const body: unknown = JSON.parse(typeof init?.body === "string" ? init.body : "{}")
        if (
          !body ||
          typeof body !== "object" ||
          !("remember" in body) ||
          typeof body.remember !== "boolean"
        )
          throw new Error("Invalid demo publishing preference.")

        remember = body.remember
        data = { remember }
      } else if (path === "/api/agent/next") data = { command: null }
      else if (withShareLinks && path.startsWith("/api/hub/share-links/")) {
        const body: unknown = JSON.parse(typeof init?.body === "string" ? init.body : "{}")
        if (!body || typeof body !== "object") throw new Error("Invalid demo sharing input.")
        if (path.endsWith("/context")) {
          data = {
            target: "storybook-share-target",
            hubOrigin: hub?.hubOrigin,
            repository: hub?.repository,
            branch: hub?.branch,
            prototype: hub?.prototype,
          }
        } else if (path.endsWith("/list")) {
          data = { shareLinks: links, hasMore: false, nextCursor: null }
        } else if (path.endsWith("/create") && "label" in body && "expiration" in body) {
          if (typeof body.label !== "string" || !hub?.prototype?.build)
            throw new Error("Invalid demo share creation.")
          const days =
            body.expiration === "one_day" ? 1 : body.expiration === "thirty_days" ? 30 : 7
          const id = nextId++
          const link: ShareLink = {
            id,
            label: body.label.trim(),
            buildNumber: hub.prototype.build.number,
            url: `https://hub.example.com/share/12345678-1234-1234-1234-${String(id).padStart(12, "0")}`,
            createdAt: new Date().toISOString(),
            createdBy: { login: "octocat", name: "The Octocat" },
            expiresAt:
              body.expiration === "never"
                ? null
                : new Date(Date.now() + days * 86_400_000).toISOString(),
          }
          links = [link, ...links]
          data = link
        } else if (path.endsWith("/delete") && "id" in body) {
          links = links.filter((link) => link.id !== body.id)
          data = { deleted: true }
        } else if (path.endsWith("/open")) {
          data = { opened: true }
        } else throw new Error("Unknown demo sharing action.")
      } else if (path === "/api/publish" && state) {
        state = {
          ...state,
          publishRequest: {
            state: "requested",
            requestedAt: new Date().toISOString(),
            commitSha: state.stats.commitSha,
          },
        }
        data = {
          message:
            "Demo only: Publish would push this branch and wait for its Hub Build. Select another scenario to continue.",
        }
      } else if (path === "/api/hub/prototype" && hub?.prototype) {
        hub = { ...hub, prototype: { ...hub.prototype, registered: true, published: true } }
        data = hub.prototype
      } else if (path === "/api/hub/comments")
        data = { comments: [], hasMore: false, nextCursor: null }
      else if (path === "/api/hub/events") {
        return new Response(
          new ReadableStream({
            start(controller) {
              init?.signal?.addEventListener("abort", () => controller.close(), { once: true })
            },
          }),
        )
      } else {
        return new Response(
          JSON.stringify({
            error:
              "Demo only: this action is disabled. Select another scenario; no real API was called.",
          }),
          { status: 409 },
        )
      }
      return new Response(JSON.stringify(data), { headers: { "Content-Type": "application/json" } })
    }
    const timer = window.setTimeout(() => setReady(true), 0)
    return () => {
      window.clearTimeout(timer)
      window.fetch = originalFetch
    }
  }, [scenario, withShareLinks])
  return (
    <div className="publication-demo">
      <div className="publication-demo-canvas">
        {ready ? (
          <App config={{ prototypeUrl, name: "Welcome prototype", token: "fixture-only" }} />
        ) : null}
      </div>
    </div>
  )
}

const configuredPrototypeUrl: unknown = import.meta.env.VITE_STORYBOOK_PROTOTYPE_URL
const meta = {
  title: "Components/Prototype canvas/Publication example",
  component: PublicationDemo,
  parameters: {
    layout: "fullscreen",
    docs: {
      description: {
        component:
          "Uses story-only fixtures. No real commits, pushes, publication, or public share links. Open never launches a browser.",
      },
    },
  },
  args: {
    scenario: "Unpublished branch",
    prototypeUrl:
      typeof configuredPrototypeUrl === "string"
        ? configuredPrototypeUrl
        : "http://127.0.0.1:38763/",
  },
  argTypes: { scenario: { control: "select", options: Object.keys(publicationExamples) } },
  render: (args) => <PublicationDemo key={`${args.scenario}/${args.withShareLinks}`} {...args} />,
} satisfies Meta<typeof PublicationDemo>

export default meta
type Story = StoryObj<typeof meta>
export const Playground: Story = {
  parameters: {
    docs: {
      description: {
        story:
          "Use the Light appearance and Dark appearance buttons to switch the preview and lower canvas UI together. The URL bar retains the Copilot app theme, with a system-theme fallback outside Copilot. Button colors switch immediately without transitions or backdrop blur. Open Controls, Hub, or a dialog to review the selected preview appearance on those surfaces.",
      },
    },
  },
}
export const Queued: Story = { args: { scenario: "Build queued" } }
export const Importing: Story = { args: { scenario: "Awaiting Hub import" } }
export const AutomaticPublication: Story = { args: { scenario: "Automatic publication" } }
export const AutomaticPublicationFailed: Story = {
  args: { scenario: "Automatic publication failed" },
}
export const WriteAccessRequired: Story = { args: { scenario: "Write access required" } }
export const MissingRemoteBranch: Story = {
  args: { scenario: "Missing remote branch" },
  parameters: {
    docs: {
      description: {
        story:
          "The critical banner separates Branch not eligible for Hub registration from The branch no longer exists on the remote repository.",
      },
    },
  },
}
export const RegistrationAwaitingBuild: Story = {
  args: { scenario: "Registration awaiting Build" },
}
export const UnknownRegistrationReason: Story = {
  args: { scenario: "Unknown registration reason" },
}
export const Failed: Story = { args: { scenario: "Build failed" } }
export const Ready: Story = { args: { scenario: "Published" } }
export const ShareManagement: Story = {
  args: {
    scenario: "Published",
    withShareLinks: true,
    prototypeUrl:
      typeof configuredPrototypeUrl === "string"
        ? configuredPrototypeUrl
        : "http://localhost:5173/",
  },
}
export const NarrowShareManagement: Story = {
  ...ShareManagement,
  render: (args) => (
    <div style={{ width: "24rem", maxWidth: "100%", height: "100vh" }}>
      <PublicationDemo {...args} />
    </div>
  ),
}
