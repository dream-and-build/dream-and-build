import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Feature } from '../types'

const PANE = 'features'
const TITLE = '🧩 Наши фичи'
// The catalog lives beside the copies prepared for GitHub; edit it there.
const CATALOG = 'C:/Users/Гении/Documents/Claude — утилиты для GitHub/features.json'

const features = atom({ plugin: 'features-board', key: 'features' } as const, [])

type Catalog = { openIn?: string[]; features?: Feature[] }

const load = async ($: EngineInterface): Promise<Catalog> => {
  try {
    return JSON.parse(await $.fs.read(CATALOG)) as Catalog
  } catch {
    return {}
  }
}

const refresh = async ($: EngineInterface) => {
  const list = (await load($)).features ?? []
  await update($, features, () => list)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.command.register({ name: 'features', description: 'Открыть панель с нашими фичами' })
    const catalog = await load($)
    await update($, features, () => catalog.features ?? [])
    $.clock.every(30000, () => refresh($))
    // Opens by itself only in the sessions the catalog names; elsewhere /features opens it.
    if ((catalog.openIn ?? []).includes(await $.session.id())) void $.ui.open({ id: PANE, title: TITLE })
    return result
  })

  on('command.run', { command: 'features' }, async $ => {
    await refresh($)
    await $.ui.open({ id: PANE, title: TITLE })
    return { text: 'Панель с фичами открыта.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = await read($, features)

    return (
      <Box flexDirection="column">
        {list.length === 0 && <Text dimColor>Список пуст: features.json не найден.</Text>}
        {list.map(f => (
          <Box flexDirection="column" marginBottom={1}>
            <Text bold>{f.name}</Text>
            <Text dimColor>
              {f.about}
              {f.status ? ` · ${f.status}` : ''}
            </Text>
          </Box>
        ))}
      </Box>
    )
  })
}
