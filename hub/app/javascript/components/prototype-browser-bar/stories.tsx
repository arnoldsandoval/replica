import type { Meta, StoryObj } from "@storybook/react-vite"
import type { CSSProperties } from "react"

import { BrowserBar } from "."

const meta = {
  title: "Components/Prototype canvas/Browser bar",
  component: BrowserBar,
  decorators: [
    (Story) => (
      <div style={{ width: "100%", minWidth: 320 }}>
        <Story />
      </div>
    ),
  ],
  args: {
    address: "http://localhost:5173/#/cli/cli/tree/main",
    canGoBack: true,
    canGoForward: false,
    appearance: "light",
    onAppearanceChange: () => {},
    onBack: () => {},
    onForward: () => {},
    onNavigate: () => {},
    onOpenTab: async () => {},
    onReload: () => {},
  },
} satisfies Meta<typeof BrowserBar>

export default meta
type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const Dark: Story = {
  args: { appearance: "dark" },
  globals: { colorMode: "night" },
}

export const Tinted: Story = {
  globals: { colorMode: "day" },
  decorators: [
    (Story) => (
      <div
        style={
          {
            "--background-color-default": "#f2eee5",
            "--text-color-default": "#302b24",
            "--text-color-muted": "#665e52",
            "--border-color-default": "#c9c0b1",
            "--color-focus-outline": "#7757a8",
            "--true-color-red": "#b43838",
          } as CSSProperties
        }
      >
        <Story />
      </div>
    ),
  ],
}

export const Narrow: Story = {
  globals: { viewport: { value: "mobile" } },
}
