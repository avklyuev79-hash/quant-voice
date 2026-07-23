#!/bin/bash
#
#  fetch-model.sh — загрузка модели WhisperKit одной командой.
#
#  Зачем отдельный скрипт, если в приложении есть пункт меню: пункт меню
#  требует найти значок в строке меню и пройти два подменю. Здесь — одна
#  вставка в терминал. Кладёт модель ровно туда, где её ищет ModelManager:
#  ~/Library/Application Support/QuantVoice/models/argmaxinc/whisperkit-coreml/<вариант>
#
#  Использование:
#    ./scripts/fetch-model.sh            # обычный: large-v3-turbo, 626 МБ
#    ./scripts/fetch-model.sh fast       # быстрый: small, 216 МБ
#    ./scripts/fetch-model.sh accurate   # точный: large-v3, 947 МБ
#

set -euo pipefail

REPO="argmaxinc/whisperkit-coreml"

case "${1:-standard}" in
    fast)     VARIANT="openai_whisper-small_216MB" ;;
    standard) VARIANT="openai_whisper-large-v3-v20240930_626MB" ;;
    accurate) VARIANT="openai_whisper-large-v3_947MB" ;;
    *)        VARIANT="$1" ;;  # можно передать имя варианта целиком
esac

DEST="$HOME/Library/Application Support/QuantVoice/models/$REPO/$VARIANT"

echo "→ Модель: $VARIANT"
echo "→ Куда:   $DEST"
echo

# Список файлов берём у Hugging Face, а не зашиваем: у вариантов разный набор
# артефактов, и захардкоженный список молча устареет при смене версии модели.
echo "→ Запрашиваю список файлов…"
# Тянем и размер: он нужен, чтобы отличить «файл уже целиком скачан» от
# «оборвалось на середине». Формат строки: <размер>\t<путь>.
FILES=$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    "https://huggingface.co/api/models/$REPO/tree/main/$VARIANT?recursive=true" \
    | python3 -c 'import json,sys
for e in json.load(sys.stdin):
    if e["type"] == "file":
        size = e.get("lfs", {}).get("size", e["size"])
        print(str(size) + "\t" + e["path"])')

if [ -z "$FILES" ]; then
    echo "✗ Список файлов пуст — проверь имя варианта и доступ к huggingface.co"
    exit 1
fi

COUNT=$(echo "$FILES" | wc -l | tr -d ' ')
echo "→ Файлов: $COUNT. Качаю (~сотни МБ, это несколько минут)…"
echo

mkdir -p "$DEST"

INDEX=0
while IFS=$'\t' read -r expected path; do
    INDEX=$((INDEX + 1))
    # path приходит как "<вариант>/AudioEncoder.mlmodelc/…" — префикс варианта
    # убираем, иначе получится вложенная папка с тем же именем.
    RELATIVE="${path#$VARIANT/}"
    TARGET="$DEST/$RELATIVE"
    mkdir -p "$(dirname "$TARGET")"

    # Уже целиком на месте — пропускаем. Это делает скрипт перезапускаемым:
    # оборвалась сеть на десятом файле — просто запусти снова, первые девять
    # не потрогаются. Заодно спасает от ошибки 416 у --continue-at на готовом файле.
    if [ -f "$TARGET" ]; then
        actual=$(stat -f%z "$TARGET" 2>/dev/null || echo 0)
        if [ "$actual" = "$expected" ]; then
            printf "  [%2d/%s] %s — уже есть\n" "$INDEX" "$COUNT" "$RELATIVE"
            continue
        fi
    fi

    printf "  [%2d/%s] %s\n" "$INDEX" "$COUNT" "$RELATIVE"

    # Hugging Face из России рвёт соединение регулярно, поэтому: --continue-at
    # докачивает с места обрыва (420-мегабайтный weight.bin иначе пришлось бы
    # качать заново), --retry сам переживает разрывы, а внешний цикл добивает
    # то, что не пережил даже --retry.
    ATTEMPT=1
    until curl -fL --progress-bar --continue-at - \
              --retry 8 --retry-delay 3 --retry-all-errors \
              --connect-timeout 30 \
              "https://huggingface.co/$REPO/resolve/main/$path" \
              -o "$TARGET"; do
        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -gt 10 ]; then
            echo "✗ Не скачался за 10 попыток: $RELATIVE"
            echo "  Похоже, huggingface.co режется провайдером. Включи VPN и запусти скрипт снова —"
            echo "  уже скачанное сохранится, докачает только остаток."
            exit 1
        fi
        echo "  ↻ обрыв, попытка $ATTEMPT…"
        sleep 3
    done
done <<< "$FILES"

echo
# --- Токенайзер ---------------------------------------------------------
#
# Модель без токенайзера бесполезна: WhisperKit грузит веса, а потом идёт за
# tokenizer.json. Приложению сеть запрещена (ТЗ 7.2, `download: false`), но
# запрет распространяется на модель — за токенайзером WhisperKit всё равно
# лезет в Hub, и на заблокированном huggingface.co это выглядит как вечное
# «Распознаю…»: не ошибка, а зависший сетевой запрос.
#
# Поэтому кладём токенайзер рядом сами, в ту самую папку, которую WhisperKit
# проверяет первой: <downloadBase>/models/<репозиторий-токенайзера>
# (ModelUtilities.loadTokenizer → hubApi.localRepoLocation).
case "$VARIANT" in
    *small*)    TOKENIZER_REPO="openai/whisper-small" ;;
    *large-v3*) TOKENIZER_REPO="openai/whisper-large-v3" ;;
    *large-v2*) TOKENIZER_REPO="openai/whisper-large-v2" ;;
    *)          TOKENIZER_REPO="openai/whisper-large-v3" ;;
esac

TOKENIZER_DEST="$HOME/Library/Application Support/QuantVoice/models/$TOKENIZER_REPO"
echo "→ Токенайзер: $TOKENIZER_REPO (~4 МБ)"
mkdir -p "$TOKENIZER_DEST"

# Веса (.safetensors, .bin) не трогаем — нужны только текстовые артефакты.
for file in tokenizer.json tokenizer_config.json config.json generation_config.json \
            special_tokens_map.json added_tokens.json vocab.json merges.txt \
            normalizer.json preprocessor_config.json; do
    target="$TOKENIZER_DEST/$file"
    [ -s "$target" ] && continue
    curl -fL --silent --show-error --retry 8 --retry-delay 3 --retry-all-errors \
        "https://huggingface.co/$TOKENIZER_REPO/resolve/main/$file" \
        -o "$target" || rm -f "$target"   # часть файлов есть не у всех вариантов
done

if [ ! -s "$TOKENIZER_DEST/tokenizer.json" ]; then
    echo "✗ Токенайзер не скачался — без него распознавание зависнет на «Распознаю…»"
    echo "  Включи VPN и запусти скрипт снова."
    exit 1
fi
echo "✓ Токенайзер на месте"
echo

# Та же проверка, что делает ModelManager.integrity: без любого из этих
# артефактов приложение сочтёт модель неустановленной и промолчит.
MISSING=""
for artifact in MelSpectrogram AudioEncoder TextDecoder; do
    if [ ! -e "$DEST/$artifact.mlmodelc" ] && [ ! -e "$DEST/$artifact.mlpackage" ]; then
        MISSING="$MISSING $artifact"
    fi
done
[ -f "$DEST/config.json" ] || MISSING="$MISSING config.json"

if [ -n "$MISSING" ]; then
    echo "✗ Модель неполная, не хватает:$MISSING"
    exit 1
fi

SIZE=$(du -sh "$DEST" | cut -f1)
echo "✓ Модель на месте ($SIZE)"
echo
echo "  Осталось перезапустить приложение — модель подхватывается при старте:"
echo "    open ~/QuantVoice-build/QuantVoice.app"
