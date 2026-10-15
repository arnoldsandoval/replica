import { createRef } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { replicaBrowseData } from "@/storybook/fixtures/replica-browse"

import { PrototypePreview } from "."

const previewUrl = new URL("prototype-preview/index.html", window.location.href).toString()
const meta = {
  title: "Features/Prototype Preview",
  component: PrototypePreview,
  args: {
    address: previewUrl,
    copy: { ...replicaBrowseData, openInNewTabLabel: "Open in new tab" },
    iframeRef: createRef<HTMLIFrameElement>(),
    previewUrl,
    frameTitle: "Replica preview",
    previewTheme: "light",
  },
  decorators: [
    (Story) => (
      <div style={{ display: "flex", height: "36rem" }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof PrototypePreview>

export default meta
type Story = StoryObj<typeof meta>

export const Ready: Story = {}
