import type { ComponentType } from "react"

type PageModule = { default: ComponentType }

const viewRoot = "../../views/"
const viewExtension = ".tsx"
const pages = import.meta.glob<PageModule>("../../views/**/*.tsx", { eager: true })

export const pageIdentifierToPageComponent = Object.fromEntries(
  Object.entries(pages).map(([path, page]) => [
    path.slice(viewRoot.length, -viewExtension.length),
    page.default,
  ]),
)
