export type Feature = { name: string; about: string; status?: string }

declare module 'claude-code' {
  interface PluginState {
    'features-board': { features: Feature[] }
  }
}
