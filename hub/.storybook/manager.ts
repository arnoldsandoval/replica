import { addons } from "storybook/manager-api"
import { create } from "storybook/theming"

addons.setConfig({
  theme: create({
    base: "light",
    brandTitle: "Replica Hub",
    brandUrl: "/?path=/story/hub-design-overview--taxonomy",
    brandTarget: "_self",
    colorPrimary: "#0969da",
    colorSecondary: "#8250df",
  }),
})
