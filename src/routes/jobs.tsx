import { createFileRoute } from '@tanstack/react-router'
import { __hermesT } from '@/lib/i18n'
import BackendUnavailableState from '@/components/backend-unavailable-state'
import { usePageTitle } from '@/hooks/use-page-title'
import { getUnavailableReason } from '@/lib/feature-gates'
import { useFeatureAvailable } from '@/hooks/use-feature-available'
import { JobsScreen } from '@/screens/jobs/jobs-screen'

export const Route = createFileRoute('/jobs')({
  ssr: false,
  component: function JobsRoute() {
    usePageTitle((__hermesT || (globalThis as any).__hermesT)('page.jobs'))
    if (!useFeatureAvailable('jobs')) {
      return (
        <BackendUnavailableState
          feature="Jobs"
          description={getUnavailableReason('Jobs')}
        />
      )
    }
    return <JobsScreen />
  },
})
