export type StageState = 'done' | 'now' | 'next'
export type Stage = { name: string; state: StageState }
export type Card = {
  about: string
  stages: Stage[]
  now: string
  plans: string[]
  ideas: string[]
  updatedAt: string
}

declare module 'claude-code' {
  interface PluginState {
    'project-card': { card: Card | null }
  }
}
