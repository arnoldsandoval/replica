import { ArrowLeftIcon } from "@primer/octicons-react"
import { Heading } from "@primer/react-brand"

import { HubAlert } from "@components/hub-alert"
import { HubIconButton } from "@components/hub-icon-button"
import { PrototypeMetadataManagement } from "@features/prototype-metadata-management"
import { RepositoryWorkspace } from "@features/repository-workspace"

import type { PrototypeManagementPageData } from "./types"

import "./styles.css"

/** Gives repository writers one place to add branches and edit gallery details. */
export function PrototypeManagementPage({ data }: { data: PrototypeManagementPageData }) {
  return (
    <RepositoryWorkspace data={data}>
      <div className="prototype-management-page">
        <header className="repository-page-header prototype-management-page__header">
          <HubIconButton
            as="a"
            href={data.prototypesPath}
            data-sg-visit="true"
            icon={ArrowLeftIcon}
            variant="invisible"
            aria-label={data.backLabel}
          />

          <Heading as="h1" size="6">
            {data.pageTitle}
          </Heading>
        </header>

        <div className="prototype-management-page__content">
          {data.alert ? <HubAlert title={data.alert} variant="critical" layout="compact" /> : null}

          <PrototypeMetadataManagement
            authenticityToken={data.authenticityToken}
            data={data.management}
          />
        </div>
      </div>
    </RepositoryWorkspace>
  )
}
