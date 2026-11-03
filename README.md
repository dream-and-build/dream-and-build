# Dream & Build · Claude Code, удобный для жизни

> 🇷🇺 Я не программист. Я обычный человек, который каждый день работает с Claude Code голосом. Здесь — всё, что мы с Claude сделали, чтобы работать было удобнее: озвучка, счётчик лимитов, напоминания размяться, карточки проектов.
>
> 🇬🇧 I'm not a programmer — just a regular person who talks to Claude Code every day. These are the small tools Claude and I built to make that comfortable: voice, limit meter, stretch reminders, project cards. *(English below.)*

**ИИ — это новый телефон.** Двадцать лет назад смартфон казался игрушкой для гиков. С ИИ сейчас происходит то же самое. Каждая вещь в этом репозитории появилась из одной живой просьбы — «хочу, чтобы…» — и была сделана в разговоре с Claude.

---

## Что здесь есть

| | Что | Зачем |
|---|---|---|
| 🔋 | **[Счётчик расхода](usage-meter)** | Над полем ввода: заряд лимитов на 5 часов и неделю, время до пополнения, ⚡ сколько взяла текущая задача, 🔷 сколько вся вкладка, 💰 цена работы ИИ, 💵 цена твоего времени и итог проекта |
| 📌 | **[Карточка проекта](project-card)** | Панель справа: о чём проект, стадии, что сейчас, что дальше, 💡 идеи. Claude ведёт её сам — открыл проект и сразу вспомнил |
| 🏃 | **[Полоса разминки](move-reminder)** | Краснеет, когда сидишь слишком долго, предлагает упражнение. Кнопка «Сделал ✓» |
| 🔊 | **[Озвучка для Windows](voice-reader-windows)** | Читает ответы вслух — только той сессии, что открыта, и замолкает, пока ты говоришь или печатаешь. Ctrl+Alt+R читает любой текст на экране. Не даёт диктовке потерять последние слова. Замечает, что ты отошёл |
| 🔁 | **[Продолжить после лимита](recipes/resume-after-limit)** | Кончился лимит — пиши задачи дальше. Когда лимит вернётся, сессии сами продолжат |
| ❓ | **[Сессии, ждущие внимания](recipes/sessions-attention-watch.md)** | Помечает сессии, где Claude ждёт твоего ответа или проект давно заброшен |
| 🧩 | **[Панель фич](features-board)** | Список всего этого справа от чата |

## Как это выглядит

```
🔋 ▰▰▰▰▱ 79% ⏱ 3ч19м   📅 ▰▰▰▱▱ 63% ⏱ 4д23ч   ⚡ 2,5%   🔷 7,3%   💰 $12,40   💵 $206 · 6ч52м   = $218,40
```

*Скриншоты появятся здесь.*

## Как поставить

Большая часть — **моды** для Claude Code. Ставятся двумя командами прямо в Claude Code:

```
/plugin marketplace add filosofzem-debug/dream-and-build
/plugin install usage-meter@dream-and-build
```

Вместо `usage-meter` — любой мод: `project-card`, `move-reminder`, `features-board`.

Или проще: скачай репозиторий (зелёная кнопка **Code → Download ZIP**) и скажи Claude Code: *«Подключи мод из этой папки»*.

Озвучка — это скрипты PowerShell для Windows, её тоже проще всего попросить поставить самого Claude: *«Поставь озвучку из папки voice-reader-windows»*.

> ⚠️ Это черновики из живой жизни. Кое-где в коде ещё зашиты мои пути к папкам и русские названия кнопок приложения — Claude поправит их под тебя за минуту.

## Как это делается

1. Говорю голосом, что мне мешает или чего хочется.
2. Claude предлагает, как сделать, и делает.
3. Пробую в жизни, говорю, что не так.
4. Когда вещь прижилась — она попадает сюда.

Об этом же — в каналах: [Telegram EN](https://t.me/dream_and_build) · [Telegram RU](https://t.me/dreamandbuild_ru)

---

## 🇬🇧 English

I'm not a programmer. Every tool here started as a spoken wish to Claude Code — *"I want it to…"* — and was built in that conversation.

- 🔋 **usage-meter** — limit batteries (5-hour and weekly), time to refill, how much the current task and the whole tab took, AI cost, your own time's cost, and the project total.
- 📌 **project-card** — a side panel with what the project is, its stages, what's now, what's next and open ideas. Claude keeps it up to date.
- 🏃 **move-reminder** — a band that turns red when you've sat too long and suggests an exercise.
- 🔊 **voice-reader-windows** — reads replies aloud (only the open session), pauses while you talk or type, Ctrl+Alt+R reads any text, keeps dictation from losing the last words.
- 🔁 **resume-after-limit** — out of usage? Keep writing tasks; sessions continue on their own when the limit comes back.
- ❓ **sessions-attention-watch** — flags sessions waiting for you.

Install in Claude Code: `/plugin marketplace add filosofzem-debug/dream-and-build`, then `/plugin install usage-meter@dream-and-build` (or `project-card`, `move-reminder`, `features-board`). Drafts from real life — some paths and Russian UI labels are hard-coded; Claude will adapt them for you.

**Dream & Build** — *AI is the new phone.*
