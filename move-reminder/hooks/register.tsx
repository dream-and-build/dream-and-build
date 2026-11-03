import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Status } from '../types'

// The log is shared with the pinned «Физическая активность» session.
const LOG = 'C:/Users/Гении/Documents/Физическая активность/activity-log.json'
// The pinned session that keeps the journal; «Сделал ✓» pressed elsewhere is reported there.
const ACTIVITY_SESSION = 'local_03ecd570-fd1c-46e1-bcf3-4faaccf3b9bb'
const GOAL_BREAKS = 8
const GOAL_MINUTES = 30

const EXERCISES: Record<1 | 2 | 3, string[]> = {
  1: [
    'Встаньте, 10 раз потянитесь вверх на носках, 30 шагов на месте',
    '20 подъёмов на носки и круги плечами: 10 вперёд, 10 назад',
    'Растяжка груди в дверном проёме 30 секунд, 10 раз сведите лопатки',
    '10 наклонов к полу и 10 поворотов корпуса',
  ],
  2: [
    '15 приседаний и 10 отжиманий от стола',
    'Выпады: по 8 на каждую ногу, потом «стульчик» у стены 30 секунд',
    'Планка 30 секунд два раза, между ними 20 приседаний',
    'Подъём по лестнице на 2–3 пролёта',
  ],
  3: [
    'Выйдите на улицу: быстрая прогулка 5–10 минут вокруг дома',
    'Прогулка быстрым шагом 10 минут, по дороге смотрите вдаль',
    'Улица: 5 минут ходьбы, потом 15 приседаний',
  ],
}

const COLORS = ['inactive', '#e6c229', '#ff8c1a', '#e5484d'] as const
const TITLES = [
  '',
  'Пора встать на пару минут',
  'Пора размяться',
  'Вы засиделись — выйдите на улицу',
]

type Entry = { at: string; what: string; minutes: number; kind: string }
type Log = {
  lastBreakAt: string | null
  snoozeUntil: string | null
  dayStart: { date: string; at: string } | null
  entries: Entry[]
}

const status = atom({ plugin: 'move-reminder', key: 'status' } as const, null, {
  shape: 'status-1',
})
const pick = atom({ plugin: 'move-reminder', key: 'pick' } as const, 0)
const blink = atom({ plugin: 'move-reminder', key: 'blink' } as const, false)

// Заряд садится за 60 минут без перерыва и снова полный после разминки.
const CELLS = 20
const FULL_MINUTES = 60
const chargeOf = (s: Status) =>
  s.isDayStarted ? Math.max(0, Math.min(100, Math.round(100 - (s.sitting / FULL_MINUTES) * 100))) : 100
const chargeColor = (pct: number) =>
  pct > 75 ? '#3b82f6' : pct > 50 ? '#22c55e' : pct > 30 ? '#e6c229' : pct > 15 ? '#ff8c1a' : '#e5484d'

const pad = (n: number) => String(n).padStart(2, '0')
const dayOf = (ms: number) => {
  const d = new Date(ms)

  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

const loadLog = async ($: any): Promise<Log> => {
  try {
    const log = JSON.parse(await $.fs.read(LOG))

    return { lastBreakAt: null, snoozeUntil: null, dayStart: null, entries: [], ...log }
  } catch {
    return { lastBreakAt: null, snoozeUntil: null, dayStart: null, entries: [] }
  }
}

const saveLog = ($: any, log: Log) => $.fs.write(LOG, JSON.stringify(log, null, 2) + '\n')

const levelOf = (minutes: number): Status['level'] =>
  minutes >= 60 ? 3 : minutes >= 45 ? 2 : minutes >= 30 ? 1 : 0

const refresh = async ($: any) => {
  const now = await $.clock.now()
  const log = await loadLog($)
  const today = dayOf(now)
  const isDayStarted = log.dayStart?.date === today
  const since = Math.max(
    log.lastBreakAt ? Date.parse(log.lastBreakAt) : 0,
    isDayStarted ? Date.parse(log.dayStart!.at) : now,
  )
  const sitting = Math.max(0, Math.round((now - since) / 60_000))
  const isSnoozed = log.snoozeUntil !== null && Date.parse(log.snoozeUntil) > now
  const level = isSnoozed ? 0 : levelOf(sitting)
  const todays = log.entries.filter(one => dayOf(Date.parse(one.at)) === today)
  const list = EXERCISES[level === 0 ? 1 : level]
  const offset = await read($, pick)
  const next: Status = {
    isDayStarted,
    sitting,
    level,
    isSnoozed,
    breaksToday: todays.length,
    minutesToday: todays.reduce((sum, one) => sum + (one.minutes || 0), 0),
    exercise: list[(new Date(now).getHours() + offset) % list.length],
  }
  await update($, status, () => next)
}

const markDone = async ($: any) => {
  const now = await $.clock.now()
  const log = await loadLog($)
  const current = await read($, status)
  const level = current?.level ?? 1
  log.entries.push({
    at: new Date(now).toISOString(),
    what: current?.exercise ?? 'Разминка',
    minutes: level === 3 ? 8 : level === 2 ? 4 : 2,
    kind: level === 3 ? 'walk' : 'break',
  })
  log.lastBreakAt = new Date(now).toISOString()
  log.snoozeUntil = null
  await saveLog($, log)
  await refresh($)
  $.ui.toast('Засчитано! Перерыв записан в журнал.')
  const done = log.entries[log.entries.length - 1]
  try {
    if ((await $.session.id()) !== ACTIVITY_SESSION) {
      await $.session.send({
        to: { sessionId: ACTIVITY_SESSION },
        text: `Отмечено кнопкой «Сделал ✓» в другой сессии: ${done.what}, ${done.minutes} мин. Журнал уже обновлён, ничего не записывай. Коротко подтверди и покажи счётчик за день.`,
      })
    }
  } catch {
    // The journal is written either way; the report is a courtesy.
  }
}

const snooze = async ($: any) => {
  const now = await $.clock.now()
  const log = await loadLog($)
  log.snoozeUntil = new Date(now + 15 * 60_000).toISOString()
  await saveLog($, log)
  await refresh($)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await refresh($)
    $.clock.every(60_000, () => refresh($))
    // Another session's «Сделал ✓» or the presence watcher writes the journal: follow it within seconds.
    let seen = 0
    $.clock.every(3_000, async () => {
      try {
        const { mtimeMs } = await $.fs.stat(LOG)
        if (mtimeMs !== seen) {
          seen = mtimeMs
          await refresh($)
        }
      } catch {
        // No journal yet.
      }
    })
    $.clock.every(700, async () => {
      const current = await read($, status)
      if (current !== null && chargeOf(current) <= 15) {
        await update($, blink, flag => !flag)
      }
    })

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    try {
      const now = await $.clock.now()
      const log = await loadLog($)
      if (log.dayStart?.date !== dayOf(now)) {
        log.dayStart = { date: dayOf(now), at: new Date(now).toISOString() }
        await saveLog($, log)
        await refresh($)
      }
    } catch {
      // A reminder must never hold up the prompt.
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const s = await read($, status)
    if (e.props.hasSurvey || s === null) {
      return next(e)
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const pct = chargeOf(s)
    const color = chargeColor(pct)
    const isLow = pct <= 15
    const isDim = isLow && (await read($, blink))
    const filled = Math.round((pct / 100) * CELLS)
    const battery = (
      <Text color={color} dimColor={isDim}>
        🔋 [{'█'.repeat(filled)}
        {'░'.repeat(CELLS - filled)}] {pct}%{isLow ? ' · нужна зарядка!' : ''}
      </Text>
    )
    const tally = `сегодня ${s.breaksToday}/${GOAL_BREAKS} перерывов, ${s.minutesToday}/${GOAL_MINUTES} мин движения`

    if (!s.isDayStarted) {
      return (
        <Box flexDirection="column">
          <Text dimColor>🧍 День ещё не начат · {tally}</Text>
          {battery}
        </Box>
      )
    }

    if (s.level === 0) {
      return (
        <Box flexDirection="column">
          <Text dimColor>
            🧍 Сижу {s.sitting} мин{s.isSnoozed ? ' (отложено)' : ''} · {tally}
          </Text>
          {battery}
        </Box>
      )
    }

    const bandColor = COLORS[s.level]

    return (
      <Box flexDirection="column">
      <Box flexDirection="column" borderStyle="round" borderColor={bandColor} paddingX={1}>
        <Text color={bandColor} weight="bold">
          {s.level === 3 ? '🔴' : s.level === 2 ? '🟠' : '🟡'} {TITLES[s.level]} · сижу {s.sitting} мин
        </Text>
        <Text>▶ {s.exercise}</Text>
        <Text dimColor>{tally}</Text>
        <Box flexDirection="row" gap={1}>
          <Button key="done" label="Сделал ✓" onPress={() => markDone($)} />
          <Button
            key="other"
            label="Другое упражнение"
            onPress={async () => {
              await update($, pick, n => n + 1)
              await refresh($)
            }}
          />
          <Button key="later" label="Через 15 мин" onPress={() => snooze($)} />
        </Box>
      </Box>
      {battery}
      </Box>
    )
  })
}
