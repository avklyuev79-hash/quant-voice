#!/bin/bash
#
#  reset-permissions.sh — полный сброс прав приложения
#
#  Стирает все выданные Quant Voice разрешения (Универсальный доступ /
#  Accessibility, Микрофон, отслеживание ввода и т.д.) через `tccutil reset`.
#  Заодно убирает накопившиеся записи от прежних ad-hoc-сборок. После сброса
#  при следующем запуске приложение запросит права заново, с чистого листа.
#
#  Зачем нужно, если есть стабильная подпись: подпись убирает НАКОПЛЕНИЕ прав,
#  а этот скрипт — на случай, когда нужна именно чистая выдача с нуля (проверка
#  онбординга, раздача беты, отладка мастера первого запуска).
#
#  Использование:
#    bash scripts/reset-permissions.sh           # только сбросить права
#    bash scripts/reset-permissions.sh --purge    # + удалить .app и закрыть его
#

set -euo pipefail

BUNDLE_ID="com.quant.voice"
APP_NAME="QuantVoice"
APP_BUNDLE="$HOME/QuantVoice-build/$APP_NAME.app"

echo "→ Сбрасываю все права ${BUNDLE_ID}…"
if tccutil reset All "$BUNDLE_ID"; then
    echo "✓ Права сброшены."
else
    echo "⚠ tccutil вернул ошибку — возможно, права уже пусты."
fi

if [ "${1:-}" = "--purge" ]; then
    echo "→ Закрываю и удаляю приложение…"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$APP_BUNDLE"
    echo "✓ Удалено: $APP_BUNDLE"
fi

echo ""
echo "  Дальше: собери и запусти заново — приложение запросит права с нуля."
echo "    ./scripts/build.sh && open \"$APP_BUNDLE\""
echo ""
echo "  Если в списке «Универсального доступа» остались серые записи от старых"
echo "  сборок — убери их кнопкой «−» один раз. Со стабильной подписью"
echo "  (./scripts/setup-signing.sh) копиться заново они уже не будут."
