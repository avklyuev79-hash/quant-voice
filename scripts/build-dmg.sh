#!/bin/bash
# Quant Voice — сборка установщика .dmg.
# Запускать НА МАКЕ после scripts/build.sh (тот собирает и подписывает .app).
# Итог: ~/QuantVoice-build/QuantVoice-<версия>.dmg — образ с приложением,
# ярлыком «Программы» и README.txt внутри.
#
# Раздача без нотаризации (ТЗ 10): подпись ad-hoc, без Apple Developer.
# На чужом маке Gatekeeper покажет предупреждение — как открыть, написано
# в README.txt внутри образа.
#
# ⚠️ Модель распознавания в образ НЕ кладётся: она весит 216–947 МБ, живёт
# в ~/Library/Application Support и качается отдельно. Это главное отличие
# от установщика Quant Keyboard, и об этом честно сказано в README.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BG="$ROOT/QuantVoice/Resources/dmg-bg.png"

OUT="$HOME/QuantVoice-build"
APP="$OUT/QuantVoice.app"
VOL="Quant Voice"

if [ ! -d "$APP" ]; then
  echo "✗ Не найден $APP"
  echo "  Сначала собери приложение:  ./scripts/build.sh"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1)"
DMG="$OUT/QuantVoice-$VERSION.dmg"

echo "→ Готовлю содержимое DMG (версия $VERSION)…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Снимаем метки iCloud/Finder, чтобы подпись не слетела.
xattr -cr "$APP" 2>/dev/null || true
cp -R "$APP" "$STAGE/QuantVoice.app"

ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'TXT'
QUANT VOICE
Голосовой ввод для macOS

ЧТО ЭТО
Нажали клавишу, сказали — текст появился в том поле, где стоял курсор.
Работает в любой программе. Всё распознавание идёт на вашем Mac:
интернет не нужен, запись никуда не отправляется. Бесплатно.

ТРЕБОВАНИЯ
macOS 14 (Sonoma) или новее, Apple Silicon (M1 и новее).
Около 1 ГБ свободного места под модель распознавания.

УСТАНОВКА
1. Перетащите значок приложения на папку «Программы» (ярлык рядом).
2. Запустите из Launchpad. Если macOS скажет, что разработчик не проверен:
   Системные настройки → Конфиденциальность и безопасность → внизу
   «Всё равно открыть».
3. Разрешите доступ к микрофону — программа спросит сама.
4. Разрешите «Универсальный доступ» (Accessibility): Системные настройки →
   Конфиденциальность и безопасность → Универсальный доступ. Без этого
   права нельзя ни поймать нажатие клавиши, ни вставить текст.

ВАЖНО: ПЕРВЫЙ ЗАПУСК ДОЛГИЙ
Модель распознавания (около 600 МБ) не входит в этот образ — её нужно
скачать один раз: значок в строке меню → «Настройки» → «Распознавание» →
кнопка загрузки. Дальше модель лежит на диске и интернет больше не нужен.

Первое включение после загрузки занимает несколько минут: macOS
подстраивает модель под ваш процессор. Это происходит ОДИН раз,
все следующие запуски — пара секунд.

Если загрузка обрывается, её можно повторить — она продолжится
с того места, где остановилась.

КАК ПОЛЬЗОВАТЬСЯ
- Удерживайте клавишу 🌐 (fn, левый нижний угол) и говорите. Отпустили —
  текст вставился. Чтобы 🌐 не дёргала заодно системное действие,
  отключите его: Системные настройки → Клавиатура → «При нажатии 🌐» →
  «Ничего не делать».
- Ctrl+Option+D — то же самое, если 🌐 занята.
- Esc — отменить, пока идёт запись или распознавание.
- Значок в строке меню → «Настройки»: хоткеи, язык, размер модели,
  словарь терминов, причёсывание текста.

СЛОВАРЬ ТЕРМИНОВ
Если программа стабильно путает какое-то название — впишите его
в «Настройки» → «Термины». Она будет и подсказывать это слово модели
заранее, и исправлять похожие ослышки, включая падежные формы.

ПРИВАТНОСТЬ
Звук с микрофона живёт только в оперативной памяти во время фразы
и стирается сразу после распознавания — на диск он не пишется никогда.
Ни запись, ни распознанный текст не уходят в сеть: программа работает
полностью офлайн. В журнале событий сохраняются только тайминги
и служебные отметки, без единого слова из ваших диктовок.

СДЕЛАНО В QUANT
Quant — агентство, которое выстраивает работу ИИ в бизнесе. Мы архитекторы
ИИ: берём процесс, поручаем его ИИ и отвечаем за результат.
Сайт:     quant-agency.ru
Почта:    hello@quant-agency.ru
Telegram: @quant_agency_bot

© 2026 Quant · Алексей Клюев
TXT

mkdir -p "$STAGE/.background"
if [ -f "$BG" ]; then
  cp "$BG" "$STAGE/.background/bg.png"
else
  echo "  ⚠ Фон $BG не найден — окно будет без картинки."
fi

echo "→ Собираю образ и оформляю окно (Finder)…"
RW="$OUT/.qv-rw.dmg"
rm -f "$RW" "$DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 2

if [ -f "$STAGE/.background/bg.png" ]; then
  osascript <<OSA || echo "  ⚠ Не удалось оформить окно (нет GUI-сессии Finder) — образ соберётся без раскладки."
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 540}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 120
    try
      set text size of vopts to 13
    end try
    set background picture of vopts to file ".background:bg.png"
    set position of item "QuantVoice.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    try
      set position of item "README.txt" of container window to {330, 330}
    end try
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  sync
fi

hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true

echo "→ Сжимаю образ…"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"

SIZE="$(du -h "$DMG" | cut -f1)"
echo ""
echo "✓ Готово:  $DMG  ($SIZE)"
echo "  Модель в образ не входит — пользователь качает её из настроек при первом запуске."
