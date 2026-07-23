#!/bin/bash
#
#  build.sh — сборка Quant Voice
#
#  Собирает через SwiftPM, БЕЗ Xcode: достаточно Command Line Tools с SDK 26+.
#  SwiftPM даёт только исполняемый файл, структуру .app-бандла собираем здесь.
#
#  Почему не Xcode: приложение простое, зависимость одна, а Xcode весит 15+ ГБ
#  и не даёт здесь ничего, кроме удобного редактора. Тем же путём идёт VoxLocal.
#
#  Результат кладётся в ~/QuantVoice-build/ — ВНЕ iCloud.
#  Метки расширенных атрибутов iCloud ломают codesign, это проверено
#  на соседнем проекте Quant Keyboard.
#
#  Скрипт идемпотентен: гонять можно сколько угодно.
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$HOME/QuantVoice-build"
APP_NAME="QuantVoice"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
CONFIG="${CONFIG:-release}"

cd "$PROJECT_DIR"

# ─────────────────────────────────────────────────────────────
# 1. Проверка инструментов
# ─────────────────────────────────────────────────────────────

echo "→ Проверяю инструменты сборки…"

if ! command -v swift >/dev/null 2>&1; then
    echo "✗ Не найден swift. Поставь Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi

SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo "0")"
SDK_MAJOR="${SDK_VERSION%%.*}"

if [ "${SDK_MAJOR:-0}" -lt 26 ] 2>/dev/null; then
    echo "✗ SDK версии $SDK_VERSION — нужен 26 или новее."
    echo "  Код использует системный движок распознавания из macOS 26."
    echo "  Обнови Command Line Tools:  xcode-select --install"
    exit 1
fi

echo "  SDK $SDK_VERSION, $(swift --version 2>/dev/null | head -1)"

# ─────────────────────────────────────────────────────────────
# 2. Сборка
# ─────────────────────────────────────────────────────────────

echo "→ Собираю ($CONFIG)…"
echo "  Первая сборка идёт дольше: качается WhisperKit."

swift build --configuration "$CONFIG"

BIN_PATH="$(swift build --configuration "$CONFIG" --show-bin-path)"
BINARY="$BIN_PATH/$APP_NAME"

if [ ! -f "$BINARY" ]; then
    echo "✗ Исполняемый файл не собрался: $BINARY"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# 3. Сборка .app-бандла
# ─────────────────────────────────────────────────────────────

echo "→ Собираю бандл приложения…"

# Приложение может быть запущено — гасим перед перезаписью,
# иначе codesign упрётся в занятый файл.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "  Закрываю запущенный экземпляр…"
    pkill -x "$APP_NAME" || true
    sleep 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/QuantVoice/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Иконка приложения. .icns собирается из iconset прямо здесь: держать
# в репозитории бинарный .icns рядом с исходными PNG — значит однажды
# забыть его пересобрать. iconutil есть в Command Line Tools.
ICONSET="$PROJECT_DIR/QuantVoice/Resources/AppIcon.iconset"
if [ -d "$ICONSET" ]; then
    if iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo "  Иконка: AppIcon.icns собрана из iconset"
    else
        echo "  ⚠ iconutil не смог собрать иконку — приложение будет с системной заглушкой"
    fi
else
    echo "  ⚠ Нет $ICONSET — иконка не собрана"
fi

# Ресурсные бандлы SwiftPM (свои и зависимостей) кладём в Resources —
# оттуда их находит рантайм.
for RESOURCE_BUNDLE in "$BIN_PATH"/*.bundle; do
    [ -e "$RESOURCE_BUNDLE" ] || continue
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
done

# ─────────────────────────────────────────────────────────────
# 4. Подпись
# ─────────────────────────────────────────────────────────────

echo "→ Подписываю…"

# Чистим расширенные атрибуты: если файлы проезжали через iCloud,
# на них остаются метки, из-за которых codesign падает.
xattr -cr "$APP_BUNDLE"

# Подпись без Apple Developer и нотаризации (ТЗ 10). Подпись обязательна —
# без неё macOS не даст выдать права Accessibility.
#
# Предпочитаем ПОСТОЯННЫЙ самоподписанный сертификат: у ad-hoc (`--sign -`)
# нет стабильной личности, cdhash меняется на каждой сборке, macOS считает
# каждую сборку новым приложением — права не переживают пересборку, а в
# «Универсальном доступе» копятся дубликаты. С постоянным сертификатом
# designated requirement стабилен: права выдаются один раз и держатся.
# Сертификат создаётся один раз: ./scripts/setup-signing.sh
SIGN_IDENTITY="Quant Voice Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "  Подпись: стабильный сертификат «$SIGN_IDENTITY»"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "  ⚠ Постоянного сертификата нет — подписываю ad-hoc."
    echo "    Права будут копиться при пересборках. Чтобы это убрать, один раз:"
    echo "      ./scripts/setup-signing.sh"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

# ─────────────────────────────────────────────────────────────
# 5. Готово
# ─────────────────────────────────────────────────────────────

echo ""
echo "✓ Собрано: $APP_BUNDLE"
echo ""
echo "  Запустить:   open \"$APP_BUNDLE\""
echo "  Логи:        ~/Library/Logs/QuantVoice/"
echo ""
echo "  После первого запуска выдай права:"
echo "    Системные настройки → Конфиденциальность и безопасность"
echo "    → Универсальный доступ → добавить QuantVoice"
echo ""
