import { createRef, useState, type ComponentProps } from "react"
import type { Meta, StoryObj } from "@storybook/react-vite"

import { HubConnectionDialog } from "."

function ConnectionDemo(args: ComponentProps<typeof HubConnectionDialog>) {
  const [status, setStatus] = useState(args.status)
  return (
    <HubConnectionDialog
      {...args}
      status={status}
      onSelectHub={(origin) => {
        setStatus({ ...status, state: "disconnected", hubOrigin: origin })
        return Promise.resolve()
      }}
    />
  )
}

const meta = {
  title: "Components/Prototype canvas/Hub connection dialog",
  component: HubConnectionDialog,
  args: {
    status: {
      state: "disconnected",
      repository: "github/prototype",
      hubOrigin: "https://hub.example.com",
    },
    connecting: false,
    error: "",
    onConnect: async () => {},
    onSelectHub: async () => {},
    onResetHub: () => Promise.resolve("https://hub.example.com"),
    onClose: () => {},
    hubButtonRef: createRef<HTMLButtonElement>(),
  },
  render: (args) => <ConnectionDemo {...args} />,
} satisfies Meta<typeof HubConnectionDialog>

export default meta
type Story = StoryObj<typeof meta>

export const Connect: Story = {}
export const Editing: Story = {
  play: async ({ canvas }) => {
    const edit = await canvas.findByRole("button", { name: "Edit Hub URL" })
    edit.click()
  },
}
export const ChooseHub: Story = {
  args: { status: { state: "unconfigured", repository: "github/prototype" } },
}
export const OpeningBrowser: Story = { args: { connecting: true } }
export const AwaitingApproval: Story = {
  play: async ({ canvas }) => {
    const group = await canvas.findByRole("group", { name: "Browser approval" })
    if (!group.querySelector("a") || !group.querySelector("button"))
      throw new Error("Pending approval needs joined link and copy actions.")
    if (group.querySelector("a") !== group.ownerDocument.activeElement)
      throw new Error("Pending approval must focus the approval link.")
  },
  args: {
    pairing: {
      verificationUrl: "https://hub.example.com/canvas/pair/ABCD1234",
      userCode: "ABCD1234",
    },
  },
}
export const BrowserUnavailable: Story = {
  args: {
    ...AwaitingApproval.args,
    error: "Could not open your browser. Open or copy the approval link below.",
  },
}
