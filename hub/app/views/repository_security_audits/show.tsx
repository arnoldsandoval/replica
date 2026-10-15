import { usePageData } from "@hooks/use-page-data"
import { useWorkspaceInbox } from "@hooks/use-workspace-inbox"
import { SecurityAuditPage } from "@pages/security-audit-page"
import type { SecurityAuditPageData } from "@pages/security-audit-page/types"

export default function RepositorySecurityAuditsShowView() {
  return <SecurityAuditPage data={useWorkspaceInbox(usePageData<SecurityAuditPageData>())} />
}
