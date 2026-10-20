# AeroFlow

Система аэропортовых оповещений: диспетчер управляет рейсами и объявлениями, а
система ставит объявления в очередь и воспроизводит их по правилам приоритета —
от рейсовых до экстренных. Развитие существующей САО с сохранением её логики
работы и аудиобиблиотеки.

Проект состоит из нескольких репозиториев; этот — корневой: общие файлы, запуск
всего стека для разработки и продакшен-развёртывание.

## Репозитории

| Репозиторий | Что это | Стек |
|---|---|---|
| [aeroflow-core](https://github.com/vasilii-kostiuc/aeroflow-core) | бизнес-логика: рейсы, объявления, шаблоны, аудиобиблиотека, пользователи | PHP, Symfony, PostgreSQL |
| [aeroflow-playback](https://github.com/vasilii-kostiuc/aeroflow-playback) | очередь воспроизведения: приоритеты, повторы, экстренный режим | PHP, Symfony, PostgreSQL |
| [aeroflow-agent](https://github.com/vasilii-kostiuc/aeroflow-agent) | локальный агент у динамиков: физически воспроизводит звук | .NET |
| [aeroflow-tts](https://github.com/vasilii-kostiuc/aeroflow-tts) | синтез речи `text → wav` для текстов объявлений | PHP, Piper |
| [aeroflow-web](https://github.com/vasilii-kostiuc/aeroflow-web) | интерфейс администратора и диспетчера | React, Mantine, TypeScript |
| [aeroflow-docs](https://github.com/vasilii-kostiuc/aeroflow-docs) | архитектура, доменная модель, задачи — источник истины | — |

## Как это связано

```text
aeroflow-web ──► aeroflow-core ──► RabbitMQ ──► aeroflow-playback ──► RabbitMQ ──► aeroflow-agent ──► динамики
                      │
                      └──► aeroflow-tts (озвучка текстов при сохранении шаблонов)
```

Core решает, *что* объявить и почему; playback — *когда* и в каком порядке;
agent — *как* физически воспроизвести.

## С чего начать

* Устройство системы — [aeroflow-docs](https://github.com/vasilii-kostiuc/aeroflow-docs):
  `README.md`, `architecture.md`, `domain-model.md`, задачи в `tasks/`.
* Запуск всего стека локально — [RUNNING.md](RUNNING.md) (`./dev.sh up`).
* Продакшен-развёртывание — [deploy/README.md](deploy/README.md).
