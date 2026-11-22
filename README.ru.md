# ClipTimbre для DaVinci Resolve

Панель для DaVinci Resolve Studio, которая находит выбранный голос, сокращает паузы и помогает проверить диалоги перед экспортом. Аудио обрабатывается локально.

[English](README.md) · [Релизы](https://github.com/0xDive/cliptimbre/releases)

![Главная вкладка ClipTimbre в DaVinci Resolve Studio](docs/screenshots/dashboard.png)

[Скриншот настроек](docs/screenshots/settings.png)

## Установка и удаление

Установите **DaVinci Resolve Studio 21** и **Python 3.12** (**3.11** на Intel Mac). На Windows on Arm используйте x64-версию Python. Перед установкой или удалением закройте Resolve.

Для версии с тегом следуйте инструкции на странице её релиза. Для текущей копии репозитория запустите подходящую команду из этой папки.

| Платформа | Установка | Удаление |
| --- | --- | --- |
| macOS | `bash ./install_macos.sh` | `bash ./uninstall_macos.sh` |
| Windows | `.\install_windows.cmd` | `.\uninstall_windows.cmd` |
| Linux | `bash ./install_linux.sh` | `bash ./uninstall_linux.sh` |

Запустите Resolve и выберите **Workspace → Scripts → ClipTimbre**. При первой установке загрузятся пакеты Python. Распознавание голоса и транскрибация загрузят модели при первом запуске.

Установка сохраняет существующие настройки и голосовые профили. Удаление убирает пункт меню и сохраняет локальные данные и окружение Python. При новой установке на Windows и Linux по умолчанию используется CPU-версия PyTorch. Передайте `--pytorch-index URL` для установки совместимой сборки с поддержкой GPU. На Apple Silicon при новой установке добавляется MLX Whisper.

На Linux используйте `zenity` для диалогов. Для Ripple Delete внутри клипов на Linux нужны X11 и `xdotool`, а на macOS — разрешение «Универсальный доступ». Панель проверена в Resolve Studio 21.0.4 на macOS. Windows и Linux ещё предстоит проверить в Resolve. [Возможности Studio](https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_Studio_21_Features.pdf)

## Использование

1. **Voice.** Выберите или создайте голосовой профиль. Запишите образцы в активный профиль или задайте временный образец с позиции курсора. **Find voice** размечает совпадения. **Correct** и **Wrong** калибруют порог профиля.
2. **Pauses.** После поиска совпадений разметьте и проверьте паузы перед запуском **Tighten pauses**. По умолчанию команда создаёт копию таймлайна и использует нативный Ripple Delete на границах клипов.
3. **YouTube Safety.** Запустите локальную транскрибацию текущего таймлайна через Whisper. Выберите найденную фразу, чтобы увидеть контекст. **Edit risk rules** открывает локальный файл правил. Сканирование помогает при редакторской проверке.
4. **Auto Censor.** Выберите **Beep**, **Smooth Mute** или **Timeline Mute**, чтобы создать обработанную копию таймлайна. Timeline Mute сохраняет раздельные дорожки и добавляет плавные переходы, если аудио можно сопоставить с исходником. Сохраняйте созданные WAV-файлы, пока проект на них ссылается.

**Diagnostics → Open data folder** открывает настройки и отчёты. Чтобы анализировать обработанный микс Resolve, задайте `"audio_source_mode": "render"` в `config.json`.

## Разработка и релизы

В `backend/` находится обработка аудио, в `resolve_lua/` — панель и интеграция с таймлайном. За установку отвечает `install.py`. Команда `python -m unittest discover -s tests` запускает тесты установщика.

GitHub Actions проверяет пул-реквесты и пуши в `main`. Для нового релиза обновите `VERSION`, сделайте коммит, поставьте соответствующий тег `vX.Y.Z` и отправьте его на GitHub. После успешных проверок GitHub опубликует релиз со списком изменений из истории коммитов и ссылками на исходники.

## Лицензия

[AGPLv3](LICENSE) · [Разрешение на интеграцию с DaVinci Resolve](LICENSE-RESOLVE-EXCEPTION.md)
