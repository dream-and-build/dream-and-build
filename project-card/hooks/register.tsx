import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Card, Stage, StageState } from '../types'

const PANE = 'project-card'
const TITLE = '📌 О проекте'
const TOOL = 'card'
// One card per session, named by the session id.
const DIR = 'C:/Users/Гении/.claude/project-cards'

const card = atom({ plugin: 'project-card', key: 'card' } as const, null)

const pathOf = async ($: EngineInterface) => `${DIR}/${await $.session.id()}.json`

const load = async ($: EngineInterface): Promise<Card | null> => {
  try {
    return JSON.parse(await $.fs.read(await pathOf($))) as Card
  } catch {
    return null
  }
}

const refresh = async ($: EngineInterface) => {
  const c = await load($)
  await update($, card, prev => (JSON.stringify(prev) === JSON.stringify(c) ? prev : c))
}

const strings = (v: unknown) =>
  Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string' && s.trim() !== '').map(s => s.trim()) : undefined

const STATES: StageState[] = ['done', 'now', 'next']
const stagesOf = (v: unknown): Stage[] | undefined =>
  Array.isArray(v)
    ? v.flatMap(s => {
        const o = s as { name?: unknown; state?: unknown }
        return typeof o?.name === 'string' && o.name.trim()
          ? [{ name: o.name.trim(), state: STATES.includes(o.state as StageState) ? (o.state as StageState) : 'next' }]
          : []
      })
    : undefined

const RULES = `Карточка проекта. Справа от чата у пользователя панель «${TITLE}»: карточка этой сессии, чтобы, открыв проект, сразу вспомнить, о чём он, где мы и какие были идеи. Ты ведёшь её инструментом mcp__project-card__${TOOL}.
- Если карточки нет, а сессия — работа над проектом (не разовый вопрос и не автоматический запуск задачи по расписанию), составь её в ближайшем ответе по всей переписке: about — 1–2 предложения, что это за проект и зачем; stages — 3–7 стадий проекта, у каждой state done (пройдена), now (идёт сейчас) или next (впереди); now — над чем работаем прямо сейчас; plans — что планируется дальше, до 5 пунктов; ideas — дополнительные идеи пользователя, которые ещё не сделаны.
- Обновляй карточку, когда сменилась стадия, текущая работа или планы. Когда пользователь высказывает идею по проекту, которую не делаем прямо сейчас, сразу добавь её через addIdea, чтобы она не потерялась. Сделанную идею убери из ideas.
- Пиши коротко, по-русски, понятными словами, без технических деталей. Пользователю об обновлении карточки отдельно не сообщай.`

const SCHEMA = {
  type: 'object',
  properties: {
    about: { type: 'string', description: 'Что это за проект и зачем, 1–2 предложения' },
    stages: {
      type: 'array',
      description: 'Все стадии проекта по порядку (заменяет прежний список)',
      items: {
        type: 'object',
        properties: { name: { type: 'string' }, state: { type: 'string', enum: STATES } },
        required: ['name', 'state'],
      },
    },
    now: { type: 'string', description: 'Над чем работаем сейчас' },
    plans: { type: 'array', items: { type: 'string' }, description: 'Что планируется дальше (заменяет прежний список)' },
    ideas: { type: 'array', items: { type: 'string' }, description: 'Все несделанные идеи (заменяет прежний список)' },
    addIdea: { type: 'string', description: 'Одна новая идея, дописывается к списку' },
  },
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.tool.register({
      name: TOOL,
      description:
        'Обновляет карточку проекта на панели справа от чата. Передавай только поля, которые меняются; списки stages, plans и ideas заменяются целиком, addIdea дописывает одну идею.',
      inputSchema: SCHEMA,
      isDeferred: false,
    })
    await $.command.register({ name: 'project', description: 'Открыть карточку проекта справа' })
    await refresh($)
    // Another session may write this card (filling cards in bulk): pick that up.
    $.clock.every(15000, () => refresh($))
    void $.ui.open({ id: PANE, title: TITLE })
    return result
  })

  on('command.run', { command: 'project' }, async $ => {
    await refresh($)
    await $.ui.open({ id: PANE, title: TITLE })
    return { text: 'Карточка проекта открыта справа.' }
  })

  on('tool.call', { tool: 'mcp__project-card__card' }, async ($, e) => {
    const input = e as unknown as Record<string, unknown>
    const prev = (await load($)) ?? { about: '', stages: [], now: '', plans: [], ideas: [], updatedAt: '' }
    const ideas = strings(input.ideas) ?? prev.ideas
    const idea = typeof input.addIdea === 'string' ? input.addIdea.trim() : ''
    const next: Card = {
      about: typeof input.about === 'string' ? input.about.trim() : prev.about,
      stages: stagesOf(input.stages) ?? prev.stages,
      now: typeof input.now === 'string' ? input.now.trim() : prev.now,
      plans: strings(input.plans) ?? prev.plans,
      ideas: idea && !ideas.includes(idea) ? [...ideas, idea] : ideas,
      updatedAt: new Date().toISOString(),
    }
    await $.fs.write(await pathOf($), JSON.stringify(next, null, 2))
    await update($, card, () => next)
    return { result: 'Карточка обновлена.' }
  })

  on('prompt.compose', async ($, e, next) => {
    const out = await next(e)
    const c = await read($, card)
    const text = `${RULES}\nТекущая карточка: ${c ? JSON.stringify({ ...c, updatedAt: undefined }) : 'пока нет'}`
    return { sections: [...out.sections, { id: 'project-card:rules', text, scope: 'session' as const }] }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const c = await read($, card)

    if (!c) {
      return (
        <Box flexDirection="column">
          <Text dimColor>Карточки пока нет. Она появится после следующего ответа в этой сессии.</Text>
          <Box marginTop={1}>
            <Button
              key="make"
              label="Составить сейчас"
              onPress={() => void $.prompt.submit({ text: 'Составь карточку проекта для панели «О проекте».', asUser: true })}
            />
          </Box>
        </Box>
      )
    }

    const mark = (s: Stage) => (s.state === 'done' ? '✅' : s.state === 'now' ? '▶' : '○')
    const when = c.updatedAt ? new Date(c.updatedAt) : null
    const pad = (n: number) => String(n).padStart(2, '0')

    return (
      <Box flexDirection="column">
        {c.about !== '' && <Text>{c.about}</Text>}

        {c.stages.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>Стадии</Text>
            {c.stages.map(s => (
              <Text bold={s.state === 'now'} dimColor={s.state === 'next'}>
                {mark(s)} {s.name}
              </Text>
            ))}
          </Box>
        )}

        {c.now !== '' && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>Сейчас</Text>
            <Text>{c.now}</Text>
          </Box>
        )}

        {c.plans.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>Дальше</Text>
            {c.plans.map(p => (
              <Text>• {p}</Text>
            ))}
          </Box>
        )}

        {c.ideas.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>💡 Идеи</Text>
            {c.ideas.map(i => (
              <Text>• {i}</Text>
            ))}
          </Box>
        )}

        {when && (
          <Box marginTop={1}>
            <Text dimColor>
              обновлено {pad(when.getDate())}.{pad(when.getMonth() + 1)} {pad(when.getHours())}:{pad(when.getMinutes())}
            </Text>
          </Box>
        )}
      </Box>
    )
  })
}
