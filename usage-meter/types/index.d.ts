export type Limit = { kind: string; used: number; resetsAt?: string }
export type Sums = { five: number; week: number }
export type Snap = { mine: number; total: number; five?: Limit; week?: Limit }

declare module 'claude-code' {
  interface PluginState {
    'usage-meter': {
      limits: Limit[] | null
      tick: number
      sums: Sums
      taskBase: number | null
      snap: Snap | null
      spent: number
      humanMin: number
      rate: number
    }
  }
}
