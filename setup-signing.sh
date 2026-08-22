#!/bin/bash
# Создаёт локальную самоподписанную подпись для приложения.
#
# Зачем: при ad-hoc подписи (codesign --sign -) хеш бинарника меняется с каждой
# сборкой, и macOS перестаёт узнавать приложение — выданное разрешение
# «Универсальный доступ» слетает. Стабильный сертификат этого не допускает:
# система запоминает не хеш, а связку «идентификатор + сертификат».
#
# Наружу ничего не уходит: ключ и сертификат живут только в этой связке ключей.
set -e
cd "$(dirname "$0")"

NAME="Golos Local Signing"
DIR="signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Подпись «$NAME» уже есть, ничего делать не нужно."
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

cat > "$DIR/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Golos Local Signing
O = Local Development
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# Системный LibreSSL, а не openssl из PATH: у OpenSSL 3 формат PKCS12 новее,
# чем понимает утилита security, и импорт падает на «MAC verification failed».
OPENSSL=/usr/bin/openssl

echo "1/4  Генерирую ключ и сертификат на 10 лет…"
$OPENSSL req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -config "$DIR/openssl.cnf" 2>/dev/null

# Пустой пароль у контейнера security переваривает плохо — даём временный.
P12PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
$OPENSSL pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -out "$DIR/identity.p12" -passout "pass:$P12PASS" -name "$NAME" 2>/dev/null
chmod 600 "$DIR"/*.pem "$DIR/identity.p12"

echo "2/4  Кладу в связку ключей…"
# -T /usr/bin/codesign разрешает подписывать без запроса пароля каждый раз.
security import "$DIR/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "3/4  Помечаю как доверенную для подписи кода…"
echo "     Система спросит пароль — это нормально, введи его сам."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

echo "4/4  Проверяю…"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo
    echo "Готово. Теперь: ./build.sh — подпись подхватится сама."
    echo "Разрешение в «Универсальном доступе» придётся выдать один последний раз."
else
    echo "Не получилось: подпись в списке не появилась." >&2
    exit 1
fi
