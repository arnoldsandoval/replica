import { createRef } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { replicaBrowseData } from "@/storybook/fixtures/replica-browse"
import { PrototypePreview } from "@features/prototype-preview"

const previewUrl = new URL(
  "/prototype-preview/build-controls/index.html",
  window.location.href,
).toString()
const meta = {
  title: "Features/Build Controls",
  component: PrototypePreview,
  args: {
    address: previewUrl,
    copy: replicaBrowseData,
    iframeRef: createRef<HTMLIFrameElement>(),
    previewUrl,
    frameTitle: "Static Build controls fixture",
    previewTheme: "light",
    controlsIdentity: "storybook-public-build-controls",
  },
  decorators: [
    (Story) => (
      <div style={{ display: "flex", height: "40rem" }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof PrototypePreview>

export default meta
type Story = StoryObj<typeof meta>

export const Ready: Story = {}
export const Minimized: Story = { args: { minimized: true } }
export const LegacyBuild: Story = {
  args: { previewUrl: new URL("/prototype-preview/index.html", window.location.href).toString() },
}
