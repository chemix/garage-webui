#!/usr/bin/env bash
# Vygeneruje hodnotu pro AUTH_USER_PASS (bcrypt) pro garage-webui.
# Heslo se zadava interaktivne, takze neskonci v historii shellu ani v `ps`.
set -euo pipefail

USER_NAME="${1:-admin}"

case "$USER_NAME" in
  *:*) echo "CHYBA: uzivatelske jmeno nesmi obsahovat dvojtecku." >&2; exit 1 ;;
esac

if command -v htpasswd >/dev/null 2>&1; then
  OUT=$(htpasswd -nBC 10 "$USER_NAME")
elif command -v docker >/dev/null 2>&1; then
  echo "htpasswd nenalezen, pouzivam docker (httpd:alpine)." >&2
  OUT=$(docker run --rm -i httpd:alpine htpasswd -nBC 10 "$USER_NAME")
else
  echo "CHYBA: potreba htpasswd (apache2-utils) nebo docker." >&2
  exit 1
fi

case "$OUT" in
  *':$2'*) ;;
  *) echo "CHYBA: vystup nevypada jako bcrypt hash: $OUT" >&2; exit 1 ;;
esac

cat <<EOF

Vloz do Dokploy -> Environment (bez uvozovek, $ NEZDVOJUJ):

AUTH_USER_PASS=$OUT

Kdyz pises primo do docker-compose.yml, zdvoj kazdy '\$' na '\$\$',
jinak ti je Compose sezere jako interpolaci promennych.
EOF
