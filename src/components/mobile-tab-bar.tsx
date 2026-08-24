import { useNavigate, useRouterState } from '@tanstack/react-router'
import { HugeiconsIcon } from '@hugeicons/react'
import {
  BrainIcon,
  Building01Icon,
  Chat01Icon,
  Clock01Icon,
  CommandLineIcon,
  DashboardSquare01Icon,
  File01Icon,
  McpServerIcon,
  PuzzleIcon,
  Rocket01Icon,
  Settings01Icon,
  Task01Icon,
  UserGroupIcon,
} from '@hugeicons/core-free-icons'
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react'
import type { TouchEvent } from 'react'
import { cn } from '@/lib/utils'
import { hapticTap } from '@/lib/haptics'
import { useSettings } from '@/hooks/use-settings'
import { __hermesT, type TranslationKey, type LocaleId, getLocale } from '@/lib/i18n'

/** Height constant for consistent bottom insets on mobile routes with tab bar */
export const MOBILE_TAB_BAR_OFFSET = 'var(--tabbar-h, 80px)'

/**
 * Z-index layer map (documented for maintainability):
 *   z-40  — tab bar (below everything interactive)
 *   z-50  — chat composer input area
 *   z-60  — quick menus, modal sheets, overlays
 *   z-70  — composer wrapper (fixed on mobile)
 */

type TabItem = {
  id: string
  labelKey: TranslationKey
  icon: typeof Chat01Icon
  to: string
  match: (path: string) => boolean
}

export const MOBILE_NAV_TABS: Array<TabItem> = [
  {
    id: 'dashboard',
    labelKey: 'nav.home',
    icon: DashboardSquare01Icon,
    to: '/dashboard',
    match: (p) => p === '/dashboard',
  },
  {
    id: 'chat',
    labelKey: 'nav.chat',
    icon: Chat01Icon,
    to: '/chat/main',
    match: (p) => p.startsWith('/chat') || p === '/new',
  },
  {
    id: 'playground',
    labelKey: 'nav.playground',
    icon: Rocket01Icon,
    to: '/playground',
    match: (p) => p.startsWith('/playground'),
  },
  {
    id: 'files',
    labelKey: 'nav.files',
    icon: File01Icon,
    to: '/files',
    match: (p) => p.startsWith('/files'),
  },
  {
    id: 'terminal',
    labelKey: 'nav.terminal',
    icon: CommandLineIcon,
    to: '/terminal',
    match: (p) => p.startsWith('/terminal'),
  },
  {
    id: 'jobs',
    labelKey: 'nav.jobs',
    icon: Clock01Icon,
    to: '/jobs',
    match: (p) => p.startsWith('/jobs'),
  },
  {
    id: 'tasks',
    labelKey: 'nav.tasks',
    icon: Task01Icon,
    to: '/tasks',
    match: (p) => p.startsWith('/tasks'),
  },
  {
    id: 'swarm',
    labelKey: 'nav.swarm',
    icon: UserGroupIcon,
    to: '/swarm',
    match: (p) => p === '/swarm' || p.startsWith('/swarm2'),
  },

  {
    id: 'memory',
    labelKey: 'nav.memory',
    icon: BrainIcon,
    to: '/memory',
    match: (p) => p.startsWith('/memory'),
  },
  {
    id: 'skills',
    labelKey: 'nav.skills',
    icon: PuzzleIcon,
    to: '/skills',
    match: (p) => p.startsWith('/skills'),
  },
  {
    id: 'mcp',
    labelKey: 'nav.mcp',
    icon: McpServerIcon,
    to: '/mcp',
    match: (p) => p.startsWith('/mcp'),
  },
  {
    id: 'profiles',
    labelKey: 'nav.profiles',
    icon: UserGroupIcon,
    to: '/profiles',
    match: (p) => p.startsWith('/profiles'),
  },
  {
    id: 'settings',
    labelKey: 'nav.settings',
    icon: Settings01Icon,
    to: '/settings',
    match: (p) => p.startsWith('/settings'),
  },
]

export function MobileTabBar() {
  const navigate = useNavigate()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const navRef = useRef<HTMLElement>(null)

  // Drag-to-switch state
  const dragStartXRef = useRef<number | null>(null)
  const dragStartTimeRef = useRef<number | null>(null)
  const [isDragging, setIsDragging] = useState(false)

  const { settings } = useSettings()
  void settings.mobileChatNavMode // reserved for future use
  const isOnChat =
    pathname.startsWith('/chat') || pathname === '/new' || pathname === '/'

  // Always hide tab bar on chat routes — iMessage/Telegram pattern
  const isChatRoute = isOnChat

  // Drag-to-switch: horizontal swipe across pill switches tabs
  const handlePillTouchStart = useCallback((event: TouchEvent<HTMLElement>) => {
    dragStartXRef.current = event.touches[0].clientX
    dragStartTimeRef.current = Date.now()
    setIsDragging(false)
  }, [])

  const handlePillTouchMove = useCallback((_event: TouchEvent<HTMLElement>) => {
    if (dragStartXRef.current !== null) {
      setIsDragging(true)
    }
  }, [])

  const handlePillTouchEnd = useCallback(
    (event: TouchEvent<HTMLElement>) => {
      const startX = dragStartXRef.current
      dragStartXRef.current = null
      setIsDragging(false)

      if (startX === null) return
      const endX = event.changedTouches[0].clientX
      const delta = endX - startX
      const elapsed = Date.now() - (dragStartTimeRef.current ?? Date.now())
      const pillWidth = navRef.current?.getBoundingClientRect().width ?? 200
      // Fast flick (< 250ms) needs less distance, slow drag needs 20% of pill width
      const threshold = elapsed < 250 ? 20 : pillWidth * 0.2

      if (Math.abs(delta) < threshold) return

      const currentIdx = MOBILE_NAV_TABS.findIndex((tab) => tab.match(pathname))
      const nextIdx =
        delta < 0
          ? Math.min(currentIdx + 1, MOBILE_NAV_TABS.length - 1) // swipe left → next tab
          : Math.max(currentIdx - 1, 0) // swipe right → prev tab

      if (
        nextIdx !== currentIdx &&
        nextIdx >= 0 &&
        nextIdx < MOBILE_NAV_TABS.length
      ) {
        hapticTap()
        void navigate({ to: MOBILE_NAV_TABS[nextIdx].to })
      }
    },
    [navigate, pathname],
  )

  // Measure pill for --tabbar-h (~80px total = pill + bottom offset)
  useLayoutEffect(() => {
    const root = document.documentElement
    const measure = () => {
      const el = navRef.current
      if (!el) return
      const rect = el.getBoundingClientRect()
      if (rect.height <= 0) return
      // pill height + its bottom margin (safe-area + 8px) + 12px breathing room
      const safeArea =
        window.innerHeight - document.documentElement.clientHeight || 0
      const bottomInset = Math.max(safeArea, 16) + 8
      const total = Math.ceil(rect.height) + bottomInset + 12
      root.style.setProperty('--tabbar-h', `${total}px`)
    }

    measure()
    const ro = new ResizeObserver(measure)
    if (navRef.current) ro.observe(navRef.current)
    window.addEventListener('resize', measure)
    return () => {
      ro.disconnect()
      window.removeEventListener('resize', measure)
    }
  }, [])

  // Keep --tabbar-h fresh when tab bar hides/shows
  useEffect(() => {
    const root = document.documentElement
    if (isChatRoute) {
      // Tab bar hidden in chat routes — remove extra padding
      root.style.setProperty('--tabbar-h', '0px')
    } else {
      // Restore measured value on next paint
      const el = navRef.current
      if (el) {
        const rect = el.getBoundingClientRect()
        if (rect.height > 0) {
          const safeArea2 =
            window.innerHeight - document.documentElement.clientHeight || 0
          const bInset = Math.max(safeArea2, 16) + 8
          root.style.setProperty(
            '--tabbar-h',
            `${Math.ceil(rect.height) + bInset + 12}px`,
          )
        }
      }
    }
  }, [isChatRoute])

  // Re-render tab labels when the UI language changes at runtime
  const [locale, setLocaleState] = useState<LocaleId>(getLocale())
  useEffect(() => {
    const onLocaleChange = (e: Event) => {
      const detail = (e as CustomEvent<LocaleId>).detail
      setLocaleState(detail ?? getLocale())
    }
    window.addEventListener('locale-change', onLocaleChange)
    return () => window.removeEventListener('locale-change', onLocaleChange)
  }, [])

  return (
    <>
      <nav
        ref={navRef}
        className={cn(
          // Pill: in normal flow (mobile shell grid row), centered.
          // Using relative (not fixed) avoids Android gesture-bar clipping
          // and overflow:hidden ancestors entirely.
          'relative z-[80] md:hidden flex w-full justify-center pointer-events-none',
          // Keep the pill visually isolated from page and error-state backgrounds
          'bg-surface/95 shadow-lg backdrop-blur supports-[backdrop-filter]:bg-surface/90',
          'rounded-full',
          'border border-primary-200/40',
          // Inner padding
          'px-1 py-1.5',
          // Hide/show animation
          'transition-all duration-300 ease-in-out',
          isChatRoute
            ? 'translate-y-[200%] opacity-0 pointer-events-none h-0 py-0 overflow-hidden'
            : 'translate-y-0 opacity-100 mt-2 mb-2',
          isDragging ? 'cursor-grabbing' : '',
        )}
        aria-label="Mobile navigation"
        onTouchStart={handlePillTouchStart}
        onTouchMove={handlePillTouchMove}
        onTouchEnd={handlePillTouchEnd}
      >
        <div className="flex items-center gap-0 pointer-events-auto px-0.5">
          {MOBILE_NAV_TABS.map((tab, idx) => {
            const isActive = tab.match(pathname)
            const isCenter = tab.id === 'chat'
            const circleSize =
              isCenter && isActive ? 'size-8' : 'size-7'

            return (
              <button
                key={tab.id}
                type="button"
                onClick={() => {
                  // Don't fire navigate if this was a drag swipe
                  if (!isDragging) {
                    hapticTap()
                    void navigate({ to: tab.to })
                  }
                }}
                aria-current={isActive ? 'page' : undefined}
                aria-label={(__hermesT || (globalThis as any).__hermesT)(tab.labelKey)}
                className={cn(
                  // 32x32 touch target (compact to fit all 9 tabs on mobile)
                  'flex items-center justify-center',
                  'size-7 rounded-full',
                  'transition-all duration-200 active:scale-90',
                  'select-none touch-manipulation',
                  'outline-none focus:outline-none focus-visible:outline-none focus-visible:ring-0',
                )}
                data-tab-idx={idx}
              >
                <span
                  className={cn(
                    'flex items-center justify-center rounded-full transition-all duration-200',
                    circleSize,
                    isActive
                      ? 'bg-accent-500 text-white shadow-sm'
                      : 'text-primary-500',
                  )}
                >
                  <HugeiconsIcon
                    icon={tab.icon}
                    size={isCenter ? 18 : 14}
                    strokeWidth={isActive ? 2 : 1.6}
                  />
                </span>
              </button>
            )
          })}
        </div>
      </nav>
    </>
  )
}
