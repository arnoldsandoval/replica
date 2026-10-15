import { Heading, Stack, Text } from "@primer/react-brand"
import type { Meta, StoryObj } from "@storybook/react-vite"

const meta = {
  title: "Hub Design/Overview",
  parameters: {
    docs: {
      description: {
        component:
          "Storybook is Replica Hub's presentation workbench. Components, features, and pages use display-ready fixtures without Rails, Superglue, GitHub access, or persisted review data.",
      },
    },
  },
} satisfies Meta

export default meta
type Story = StoryObj<typeof meta>

export const Taxonomy: Story = {
  render: () => (
    <Stack gap="spacious" style={{ maxWidth: "48rem" }}>
      <Stack gap="condensed">
        <Heading as="h1" size="3">
          Replica Hub
        </Heading>

        <Text as="p">Build and review the Hub interface without running the application.</Text>
        <Text as="p">
          Hub UI uses Primer Brand components and tokens, with Hub controls for app-specific needs.
        </Text>
        <Text as="p">
          In Components, Brand-based means the main control renders a Primer Brand component;
          Hub-built means a custom control or composition, even when a child uses Brand.
        </Text>
      </Stack>

      {[
        ["Components", "Small reusable interface elements with no product workflow knowledge."],
        ["Features", "Product-specific compositions that accept display-ready props."],
        ["Pages", "Complete presentation surfaces driven by Oaken-based fixtures."],
      ].map(([title, description]) => (
        <Stack
          key={title}
          gap="condensed"
          padding="spacious"
          style={{
            backgroundColor: "var(--hub-canvas-default)",
            border: "1px solid var(--hub-border-default)",
            borderRadius: "var(--hub-radius-medium)",
          }}
        >
          <Heading as="h2" size="5">
            {title}
          </Heading>

          <Text>{description}</Text>
        </Stack>
      ))}
    </Stack>
  ),
}
