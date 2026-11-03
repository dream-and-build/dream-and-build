export type Status = {
  isDayStarted: boolean
  sitting: number
  level: 0 | 1 | 2 | 3
  isSnoozed: boolean
  breaksToday: number
  minutesToday: number
  exercise: string
}

declare module 'claude-code' {
  interface PluginState {
    'move-reminder': { status: Shaped<Status | null>; pick: number; blink: boolean }
  }
}
