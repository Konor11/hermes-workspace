import { useCallback, useSyncExternalStore } from 'react'

const STORAGE_KEY = 'ws.tabOrder'

type Listener = () => void
const listeners = new Set<Listener>()
let cached: string[] | null = null

function read(): string[] {
  if (cached) return cached
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    cached = raw ? (JSON.parse(raw) as string[]) : []
  } catch {
    cached = []
  }
  return cached
}

function write(order: string[]) {
  cached = order
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(order))
  } catch {
    // storage full / private mode — ignore
  }
  listeners.forEach((l) => l())
}

export function useTabOrder() {
  const order = useSyncExternalStore(
    (notify) => {
      listeners.add(notify)
      return () => listeners.delete(notify)
    },
    read,
    () => [] as string[],
  )

  const setOrder = useCallback((next: string[]) => write(next), [])
  const resetOrder = useCallback(() => write([]), [])

  return { order, setOrder, resetOrder }
}

/** Stable sort of tab ids by saved order; unknown ids keep relative position at the end. */
export function applyTabOrder<T extends { id: string }>(tabs: T[], order: string[]): T[] {
  if (!order.length) return tabs
  const rank = new Map(order.map((id, i) => [id, i]))
  return [...tabs].sort((a, b) => {
    const ra = rank.has(a.id) ? rank.get(a.id)! : Number.MAX_SAFE_INTEGER
    const rb = rank.has(b.id) ? rank.get(b.id)! : Number.MAX_SAFE_INTEGER
    return ra - rb
  })
}
