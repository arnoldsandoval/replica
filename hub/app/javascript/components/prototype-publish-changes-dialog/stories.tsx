import { createRef } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { PublishChangesDialog } from "."

const meta = {
  title: "Components/Prototype canvas/Publish changes dialog",
  component: PublishChangesDialog,
  args: {
    busy: false,
    error: "",
    remembered: false,
    returnFocusRef: createRef<HTMLButtonElement>(),
    onClose: () => undefined,
    onChoose: () => undefined,
  },
} satisfies Meta<typeof PublishChangesDialog>

export default meta
type Story = StoryObj<typeof meta>

export const UncommittedChanges: Story = {}
export const RememberedPreference: Story = {
  args: { remembered: true },
}
export const RequestFailed: Story = {
  args: { error: "The checkout changed while preparing to publish. Try again." },
}
export const Publishing: Story = { args: { busy: true } }
export const Dark: Story = { globals: { colorMode: "night" } }
