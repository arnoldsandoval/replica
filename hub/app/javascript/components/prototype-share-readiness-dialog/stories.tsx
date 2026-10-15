import { createRef } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { resolvePublication } from "@utils/resolve-prototype-publication"
import { publicationExamples } from "@utils/resolve-prototype-publication/fixtures"
import { resolveShareReadiness } from "@utils/resolve-prototype-share-readiness"
import { readinessCopy } from "@utils/resolve-prototype-share-readiness/en"
import { ShareReadinessDialog } from "."

function example(name: string) {
  const { state, hub } = publicationExamples[name]!
  return resolveShareReadiness(state, hub, resolvePublication(state, hub))
}

const meta = {
  title: "Components/Prototype canvas/Share readiness dialog",
  component: ShareReadinessDialog,
  args: {
    readiness: example("Disconnected"),
    busy: false,
    shareButtonRef: createRef<HTMLButtonElement>(),
    onClose: () => undefined,
    onConnect: () => undefined,
    onPublish: () => undefined,
    onRetry: () => undefined,
    onManage: () => undefined,
  },
} satisfies Meta<typeof ShareReadinessDialog>

export default meta
type Story = StoryObj<typeof meta>

export const Disconnected: Story = {}
export const Unpublished: Story = { args: { readiness: example("Unpublished branch") } }
const unpublished = publicationExamples["Unpublished branch"]!
const olderHub = {
  ...unpublished.hub!,
  canPublish: undefined,
  repositoryAuthorized: true,
  registrationReason: "remote_branch_missing",
}
export const OlderHubUnpublished: Story = {
  args: {
    readiness: resolveShareReadiness(
      unpublished.state,
      olderHub,
      resolvePublication(unpublished.state, olderHub),
    ),
  },
}
export const Importing: Story = { args: { readiness: example("Awaiting Hub import") } }
export const Failed: Story = { args: { readiness: example("Build failed") } }
export const VerificationError: Story = { args: { readiness: example("Remote check failed") } }
export const ReadOnly: Story = { args: { readiness: example("Write access required") } }
export const Checking: Story = { args: { readiness: example("Loading") } }
export const Ready: Story = {
  args: {
    readiness: { kind: "ready", title: readinessCopy.ready, detail: readinessCopy.readyDetail },
  },
}
export const Narrow: Story = {
  ...Unpublished,
  globals: { viewport: { value: "mobile" } },
}
