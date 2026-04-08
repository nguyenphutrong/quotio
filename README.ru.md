# Quotio

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="screenshots/menu_bar_dark.png" />
    <source media="(prefers-color-scheme: light)" srcset="screenshots/menu_bar.png" />
    <img alt="Quotio Banner" src="screenshots/menu_bar.png" height="600" />
  </picture>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey.svg?style=flat" alt="Платформа macOS" />
  <img src="https://img.shields.io/badge/language-Swift-orange.svg?style=flat" alt="Язык Swift" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat" alt="Лицензия MIT" />
  <a href="https://discord.gg/dFzeZ7qS"><img src="https://img.shields.io/badge/Discord-Присоединяйтесь-5865F2.svg?style=flat&logo=discord&logoColor=white" alt="Discord" /></a>
  <a href="README.md"><img src="https://img.shields.io/badge/lang-English-grey.svg?style=flat" alt="English" /></a>
  <a href="README.vi.md"><img src="https://img.shields.io/badge/lang-Tiếng%20Việt-red.svg?style=flat" alt="Вьетнамский" /></a>
  <a href="README.zh.md"><img src="https://img.shields.io/badge/lang-zh--CN-green.svg?style=flat" alt="Китайский" /></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/lang-Français-blue.svg?style=flat" alt="Французский" /></a>
</p>

<p align="center">
  <strong>Центр управления вашими AI-ассистентами для программирования на macOS.</strong>
</p>

Quotio — нативное приложение для macOS для управления **CLIProxyAPI** — локальным прокси-сервером, который обеспечивает работу ваших AI-агентов для программирования. Помогает управлять несколькими AI-аккаунтами, отслеживать квоты и настраивать CLI-инструменты в одном месте.

## ✨ Возможности

- **🔌 Поддержка нескольких провайдеров**: Подключайте аккаунты Gemini, Claude, OpenAI Codex, Qwen, Vertex AI, iFlow, Antigravity, Kiro, Trae и GitHub Copilot через OAuth или API-ключи.
- **📊 Режим квот без прокси**: Просматривайте квоты и аккаунты без запуска прокси-сервера — удобно для быстрой проверки.
- **🚀 Настройка агентов в один клик**: Автоопределение и настройка AI-инструментов: Claude Code, OpenCode, Gemini CLI и других.
- **📈 Панель в реальном времени**: Мониторинг трафика запросов, использования токенов и процента успешных запросов.
- **📉 Умное управление квотами**: Визуальное отслеживание квот по аккаунтам с автоматическими стратегиями переключения (Round Robin / Fill First).
- **🔑 Управление API-ключами**: Создание и управление API-ключами для локального прокси.
- **🖥️ Интеграция в меню**: Быстрый доступ к статусу сервера, обзору квот и иконкам провайдеров из строки меню.
- **🔔 Уведомления**: Оповещения о низких квотах, периодах охлаждения аккаунтов или проблемах сервиса.
- **🔄 Автообновление**: Встроенный обновлятель Sparkle для беспроблемных обновлений.
- **🌍 Многоязычность**: Поддержка английского, русского, вьетнамского и упрощённого китайского.

## 🤖 Поддерживаемые провайдеры

### AI-провайдеры
| Провайдер | Метод аутентификации |
|-----------|----------------------|
| Google Gemini | OAuth |
| Anthropic Claude | OAuth |
| OpenAI Codex | OAuth |
| Qwen Code | OAuth |
| Vertex AI | Service Account JSON |
| iFlow | OAuth |
| Antigravity | OAuth |
| Kiro | OAuth |
| GitHub Copilot | OAuth |

### Отслеживание квот IDE (только мониторинг)
| IDE | Описание |
|-----|----------|
| Cursor | Автоопределение при установке и входе |
| Trae | Автоопределение при установке и входе |

> **Примечание**: Эти IDE используются только для мониторинга использования квот. Они не могут быть провайдерами для прокси.

### Совместимые CLI-агенты
Quotio может автоматически настроить эти инструменты для работы с вашим централизованным прокси:
- Claude Code
- Codex CLI
- Gemini CLI
- Amp CLI
- OpenCode
- Factory Droid

## 🚀 Установка

### Требования
- macOS 14.0 (Sonoma) или новее
- Подключение к интернету для OAuth-аутентификации

### Homebrew (рекомендуется)
```bash
brew tap nguyenphutrong/tap
brew install --cask quotio
```

### Скачивание
Скачайте последний `.dmg` на странице [Releases](https://github.com/nguyenphutrong/quotio/releases).

> ⚠️ **Примечание**: Приложение пока не подписано сертификатом Apple Developer. Если macOS блокирует запуск, выполните:
> ```bash
> xattr -cr /Applications/Quotio.app
> ```

### Сборка из исходников

1. **Клонируйте репозиторий:**
   ```bash
   git clone https://github.com/nguyenphutrong/quotio.git
   cd Quotio
   ```

2. **Откройте в Xcode:**
   ```bash
   open Quotio.xcodeproj
   ```

3. **Соберите и запустите:**
   - Выберите схему «Quotio»
   - Нажмите `Cmd + R` для сборки и запуска

> При первом запуске приложение автоматически загрузит бинарник `CLIProxyAPI`.

## 📖 Использование

### 1. Запуск сервера
Запустите Quotio и нажмите **Start** на панели управления, чтобы инициализировать локальный прокси-сервер.

### 2. Подключение аккаунтов
Вкладка **Providers** → выберите провайдера → аутентификация через OAuth или импорт учётных данных.

### 3. Настройка агентов
Вкладка **Agents** → выберите установленного агента → **Configure** → режим Automatic или Manual.

### 4. Мониторинг использования
- **Dashboard**: Общее состояние и трафик
- **Quota**: Разбивка использования по аккаунтам
- **Logs**: Сырые логи запросов и ответов для отладки

## ⚙️ Настройки

- **Порт**: Изменение порта прокси
- **Стратегия маршрутизации**: Round Robin или Fill First
- **Автозапуск**: Запуск прокси при открытии Quotio
- **Уведомления**: Включение/выключение оповещений

## 📸 Скриншоты

### Dashboard
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/dashboard_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/dashboard.png" />
  <img alt="Dashboard" src="screenshots/dashboard.png" />
</picture>

### Providers
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/provider_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/provider.png" />
  <img alt="Providers" src="screenshots/provider.png" />
</picture>

### Agent Setup
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/agent_setup_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/agent_setup.png" />
  <img alt="Agent Setup" src="screenshots/agent_setup.png" />
</picture>

### Quota Monitoring
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/quota_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/quota.png" />
  <img alt="Quota Monitoring" src="screenshots/quota.png" />
</picture>

### Fallback Configuration
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/fallback_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/fallback.png" />
  <img alt="Fallback Configuration" src="screenshots/fallback.png" />
</picture>

### API Keys
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/api_keys_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/api_keys.png" />
  <img alt="API Keys" src="screenshots/api_keys.png" />
</picture>

### Logs
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/logs_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/logs.png" />
  <img alt="Logs" src="screenshots/logs.png" />
</picture>

### Settings
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/settings_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/settings.png" />
  <img alt="Settings" src="screenshots/settings.png" />
</picture>

### Menu Bar
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/menu_bar_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/menu_bar.png" />
  <img alt="Menu Bar" src="screenshots/menu_bar.png" height="600" />
</picture>

## 🤝 Участие в разработке

1. Сделайте Fork проекта
2. Создайте ветку для функции (`git checkout -b feature/amazing-feature`)
3. Зафиксируйте изменения (`git commit -m 'Add amazing feature'`)
4. Отправьте ветку (`git push origin feature/amazing-feature`)
5. Откройте Pull Request

## 💬 Сообщество

Присоединяйтесь к нашему Discord-сообществу за помощью, обратной связью и общением с другими пользователями:

<a href="https://discord.gg/dFzeZ7qS">
  <img src="https://img.shields.io/badge/Discord-Присоединяйтесь%20к%20сообществу-5865F2.svg?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" />
</a>

## ⭐ Star History

<picture>
  <source
    media="(prefers-color-scheme: dark)"
    srcset="
      https://api.star-history.com/svg?repos=nguyenphutrong/quotio&type=Date&theme=dark
    "
  />
  <source
    media="(prefers-color-scheme: light)"
    srcset="
      https://api.star-history.com/svg?repos=nguyenphutrong/quotio&type=Date
    "
  />
  <img
    alt="Star History Chart"
    src="https://api.star-history.com/svg?repos=nguyenphutrong/quotio&type=Date"
  />
</picture>

## 📊 Активность репозитория

![Repo Activity](https://repobeats.axiom.co/api/embed/884e7349c8939bfd4bdba4bc582b6fdc0ecc21ee.svg "Repobeats analytics image")

## 💖 Контрибьюторы

Без вас мы бы не справились. Спасибо! 🙏

<a href="https://github.com/nguyenphutrong/quotio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=nguyenphutrong/quotio" />
</a>

## 📄 Лицензия

MIT License. Подробности в файле `LICENSE`.
