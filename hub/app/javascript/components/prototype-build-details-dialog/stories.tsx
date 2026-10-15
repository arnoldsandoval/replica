import { createRef } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { BuildDetailsDialog } from "."

const meta = {
  title: "Components/Prototype canvas/Build details dialog",
  component: BuildDetailsDialog,
  args: {
    state: {
      name: "Example",
      sessionId: "11111111-2222-4333-8444-555555555555",
      stats: {
        branch: "prototype/welcome",
        comparison: { branch: "main", source: "local", behind: 0, error: null },
      },
    },
    titleButtonRef: createRef<HTMLButtonElement>(),
    onClose: () => undefined,
  },
} satisfies Meta<typeof BuildDetailsDialog>

export default meta
type Story = StoryObj<typeof meta>

export const LocalMain: Story = {}

export const BehindUpstream: Story = {
  args: {
    state: {
      ...meta.args.state,
      stats: {
        ...meta.args.state.stats,
        comparison: { branch: "origin/main", source: "upstream", behind: 2, error: null },
      },
    },
  },
}
