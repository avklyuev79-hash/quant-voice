#!/bin/bash
#
#  setup-signing.sh — постоянный самоподписанный сертификат для подписи
#
#  Проблема, которую он решает: ad-hoc подпись (`codesign --sign -`) не имеет
#  постоянной личности — cdhash меняется при каждой пересборке, и macOS видит
#  каждую сборку как НОВОЕ приложение. Из-за этого:
#    • права Accessibility/Микрофон не переживают пересборку;
#    • в «Универсальном доступе» копится по записи на каждую сборку, и удаление
#      старой версии их не убирает (macOS не чистит TCC при удалении — это
#      поведение системы, программно из приложения его не обойти).
#
#  Постоянный сертификат даёт стабильную designated requirement: все сборки
#  для macOS — одно и то же приложение. Права выдаются один раз и переживают
#  обновления, дубликаты больше не копятся.
#
#  Запускать ОДИН РАЗ на маке. Идемпотентно: если сертификат уже есть — выходит.
#  Приватного ключа Apple не требует, денег не стоит, ничего в сеть не шлёт.
#

set -euo pipefail

IDENTITY_NAME="Quant Voice Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "→ Проверяю, есть ли сертификат «${IDENTITY_NAME}»…"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ Уже есть — ничего делать не нужно."
    exit 0
fi

command -v openssl >/dev/null 2>&1 || { echo "✗ Нет openssl (он есть в любой macOS — проверь PATH)."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Конфиг через файл, а не через -addext: так работает и на LibreSSL (штатный
# openssl macOS), и на OpenSSL. Ключевое расширение — extendedKeyUsage=codeSigning,
# без него codesign сертификат не примет.
cat > "$TMP/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = Quant Voice Self-Signed
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

echo "→ Генерирую ключ и сертификат (10 лет)…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -config "$TMP/openssl.cnf" -extensions v3 >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:quantvoice -name "$IDENTITY_NAME" >/dev/null 2>&1

echo "→ Кладу в связку ключей login…"
# -T /usr/bin/codesign — разрешаем codesign пользоваться ключом.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P quantvoice \
    -T /usr/bin/codesign >/dev/null 2>&1

# Проверка результата.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo ""
    echo "✓ Готово. Сертификат «${IDENTITY_NAME}» установлен."
    echo "  Теперь ./scripts/build.sh подхватит его сам."
    echo "  При ПЕРВОЙ подписи macOS может один раз спросить пароль —"
    echo "  нажми «Всегда разрешать» (Always Allow)."
else
    echo ""
    echo "✗ Автоматически не получилось. Создай вручную (1 минута, один раз):"
    echo "    1. Открой «Связка ключей» (Keychain Access)."
    echo "    2. Меню → Ассистент сертификатов → Создать сертификат…"
    echo "    3. Имя: Quant Voice Self-Signed"
    echo "       Тип идентификации: Самоподписанный корневой (Self Signed Root)"
    echo "       Тип сертификата: Подпись кода (Code Signing)"
    echo "    4. Создать → Готово. Сертификат ляжет в связку «Вход» (login)."
    exit 1
fi
