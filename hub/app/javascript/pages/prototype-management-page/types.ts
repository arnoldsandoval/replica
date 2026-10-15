import type { RepositoryWorkspaceData } from "@features/repository-workspace/types"
import type { PrototypeMetadataManagementData } from "@features/prototype-metadata-management/types"

export interface PrototypeManagementPageData extends RepositoryWorkspaceData {
  alert: string | null
  backLabel: string
  management: PrototypeMetadataManagementData
  pageTitle: string
}
