import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

import type { Limit, Snap, Sums } from '../types'

const limits = atom({ plugin: 'usage-meter', key: 'limits' } as const, null)
// Bumped every minute so the "refills in" countdowns redraw.
const tick = atom({ plugin: 'usage-meter', key: 'tick' } as const, 0)
// This tab's own share of each limit, in percent, and the 5-hour share when the current task was given.
const sums = atom({ plugin: 'usage-meter', key: 'sums' } as const, { five: 0, week: 0 })
const taskBase = atom({ plugin: 'usage-meter', key: 'taskBase' } as const, null)
// What this tab has cost since it began, in dollars at API prices.
const spent = atom({ plugin: 'usage-meter', key: 'spent' } as const, 0)
// The person's time on this tab, in minutes, read from the transcript.
const humanMin = atom({ plugin: 'usage-meter', key: 'humanMin' } as const, 0)
const rate = atom({ plugin: 'usage-meter', key: 'rate' } as const, 30)
// The last reading the shares were counted from.
const snap = atom({ plugin: 'usage-meter', key: 'snap' } as const, null)

const LABELS: Record<string, string> = {
  five_hour: '🔋',
  seven_day: '📅',
  seven_day_opus: '📅 Opus',
  seven_day_sonnet: '📅 Sonnet',
  spend_limit: '💳',
}
const ORANGE = '#ff8c1a'
const BLUE = '#3b82f6'
const YELLOW = '#e6c229'
const GREEN = '#22c55e'
// Every tab writes what it has spent under `cost:<session>`; dropped after 8 days.
const KEEP_MS = 8 * 24 * 3600 * 1000

const toLimits = (rs: readonly SessionRateLimit[]): Limit[] =>
  rs.map(r => ({ kind: r.kind, used: r.percentUsed, resetsAt: r.resetsAt }))

const windowOf = (ls: readonly Limit[], kind: string) => ls.find(l => l.kind === kind)

type Spent = { usd: number; at: number }

// What all tabs together have spent, after recording this one's figure.
const allSpent = async ($: EngineInterface, sid: string, mine: number) => {
  const now = Date.now()
  await $.store.set(`cost:${sid}`, { usd: mine, at: now } satisfies Spent)
  let total = 0
  for (const key of await $.store.keys()) {
    if (!key.startsWith('cost:')) continue
    const s = (await $.store.get(key)) as Spent | undefined
    if (!s || now - s.at > KEEP_MS) await $.store.delete(key)
    else total += s.usd
  }
  return total
}

// How far a limit moved since the last reading; a new window starts again from zero.
const moved = (was: Snap['five'], now: Limit | undefined) => {
  if (!was || !now) return 0
  return was.resetsAt === now.resetsAt ? Math.max(0, now.used - was.used) : now.used
}

// New limits arrived: hand this tab its part of how far they moved, by its part of the money spent meanwhile.
const measure = async ($: EngineInterface, rs: readonly SessionRateLimit[]) => {
  if (!rs.length) return
  const ls = toLimits(rs)
  await update($, limits, () => ls)

  const sid = await $.session.id()
  const mine = (await $.session.usage()).cost?.usd ?? 0
  const total = await allSpent($, sid, mine)
  // The whole project's price: the session's own ledger counts from its first launch; keep the highest seen.
  const price = await update($, spent, n => Math.max(n, mine))
  await $.store.set(`spent:${sid}`, price)
  const five = windowOf(ls, 'five_hour'), week = windowOf(ls, 'seven_day')
  const was = await read($, snap)

  if (was) {
    const dMine = mine - was.mine, dTotal = total - was.total
    // A restart can set the figures back: then only take a new reading.
    if (dMine >= 0 && dTotal >= 0) {
      const part = dTotal > 0 ? Math.min(1, dMine / dTotal) : 0
      const add = { five: moved(was.five, five) * part, week: moved(was.week, week) * part }
      if (add.five > 0 || add.week > 0) {
        const next = await update($, sums, s => ({ five: s.five + add.five, week: s.week + add.week }))
        await $.store.set(`tab:${sid}`, next)
      }
    }
  }
  await update($, snap, () => ({ mine, total, five, week }))
}

// What is left, as a battery of five cells.
const battery = (used: number) => {
  const left = Math.max(0, Math.min(100, 100 - used))
  const full = Math.round(left / 20)
  return `${'▰'.repeat(full)}${'▱'.repeat(5 - full)} ${Math.round(left)}%`
}

// " ⏱ 2ч15м", " ⏱ 3д4ч".
const refillIn = (iso?: string) => {
  if (!iso) return ''
  const min = Math.max(0, Math.round((new Date(iso).getTime() - Date.now()) / 60000))
  const d = Math.floor(min / 1440), h = Math.floor((min % 1440) / 60), m = min % 60
  return ` ⏱ ${d > 0 ? `${d}д${h}ч` : h > 0 ? `${h}ч${m}м` : `${m}м`}`
}

// "2,5%": one decimal, comma as Russians write it.
const pct = (n: number) => `${(Math.round(n * 10) / 10).toString().replace('.', ',')}%`

// "$12,40".
const usd = (n: number) => `$${n.toFixed(2).replace('.', ',')}`

// The person's hourly price, kept in a file they can edit.
const RATE_FILE = 'C:/Users/Гении/.claude/project-cost.json'
const readRate = async ($: EngineInterface) => {
  try {
    const r = (JSON.parse(await $.fs.read(RATE_FILE)) as { hourlyUsd?: unknown }).hourlyUsd
    if (typeof r === 'number' && r >= 0) await update($, rate, () => r)
  } catch {
    // No file: the default stands.
  }
}

// Each prompt the person wrote costs the time since the previous reply: reading it, thinking, typing.
// A pause over 15 minutes means they were away, so it counts as 15; the session's first prompt as 5.
const CAP_MIN = 15, FIRST_MIN = 5
const readHumanTime = async ($: EngineInterface) => {
  const dir = (await $.session.cwd()).replace(/[^a-zA-Z0-9]/g, '-')
  let text: string
  try {
    text = await $.fs.read(`C:/Users/Гении/.claude/projects/${dir}/${await $.session.id()}.jsonl`)
  } catch {
    return
  }
  let minutes = 0, last = 0
  for (const line of text.split('\n')) {
    const at = /"timestamp":"([^"]+)"/.exec(line)
    if (!at) continue
    const t = Date.parse(at[1])
    if (line.includes('"origin":{"kind":"human"')) minutes += last ? Math.min(CAP_MIN, Math.max(0, (t - last) / 60000)) : FIRST_MIN
    // Bookkeeping lines land right before a prompt: count from the last reply.
    if (line.includes('"type":"assistant"')) last = t
  }
  await update($, humanMin, () => minutes)
}

// "1ч30м", "45м".
const duration = (min: number) => {
  const h = Math.floor(min / 60), m = Math.round(min % 60)
  return h > 0 ? `${h}ч${m}м` : `${m}м`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await update($, limits, () => [])
    // The tab's shares outlive app restarts in the shared store.
    const kept = (await $.store.get(`tab:${await $.session.id()}`)) as Sums | undefined
    if (kept) await update($, sums, () => kept)
    const price = (await $.store.get(`spent:${await $.session.id()}`)) as number | undefined
    if (price) await update($, spent, n => Math.max(n, price))
    await readRate($)
    await readHumanTime($)
    await measure($, (await $.session.usage()).rateLimits)
    $.clock.every(60000, () => update($, tick, n => n + 1))
    return result
  })

  // Each new task counts from this tab's 5-hour share at that moment.
  on('prompt.submit', async ($, e, next) => {
    await measure($, (await $.session.usage()).rateLimits)
    const s = await read($, sums)
    await update($, taskBase, () => s.five)
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await measure($, e.rateLimits)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    await measure($, (await $.session.usage()).rateLimits)
    await readRate($)
    await readHumanTime($)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const ls = await read($, limits)
    if (e.props.hasSurvey || ls === null) return next(e)
    await read($, tick)
    const s = await read($, sums)
    const base = await read($, taskBase)
    const cost = await read($, spent)
    const minutes = await read($, humanMin)
    const people = (minutes / 60) * (await read($, rate))
    const { Box, Text } = $.ui.resolve(e)

    const parts = ls.map(l => `${LABELS[l.kind] ?? l.kind} ${battery(l.used)}${refillIn(l.resetsAt)}`)
    if (!parts.length) parts.push('🔋 после первого ответа')

    // Other bands (the exercise reminder) draw beneath this hook: keep them, above the meter.
    const below = await next(e)
    return (
      <Box flexDirection="column">
        {below}
        <Box>
          <Text dimColor>{parts.join('   ')}   </Text>
          {base !== null && <Text color={ORANGE}>⚡ {pct(s.five - base)}   </Text>}
          <Text color={BLUE}>🔷 {pct(s.week)}   </Text>
          <Text color={YELLOW}>💰 {usd(cost)}   </Text>
          <Text color={GREEN}>{`💵 ${usd(people)} · ${duration(minutes)}   `}</Text>
          <Text bold>= {usd(cost + people)}</Text>
        </Box>
      </Box>
    )
  })
}
