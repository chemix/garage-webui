#!/usr/bin/env bash
#
# Dokonci nasazeni Garage: layout -> bucket -> access key -> overeni realnym S3 prenosem.
# Vsechno jede pres HTTP API garage-webui (/api/*), takze neni potreba SSH na server.
#
# Pouziti:
#   WEBUI_URL=https://garage-webui.example.cz \
#   S3_URL=https://s3-xxx.sslip.io \
#   BUCKET=test ./scripts/garage-setup.sh
#
# Volitelne: REGION (garage), ZONE (dc1), CAPACITY (4000000000), KEY_NAME (<bucket>-key),
#            WEBUI_USER (admin), NODE_ID (jen kdyz je v clusteru vic uzlu)
#
set -euo pipefail

WEBUI_URL="${WEBUI_URL:-}"
S3_URL="${S3_URL:-}"
BUCKET="${BUCKET:-test}"
REGION="${REGION:-garage}"
ZONE="${ZONE:-dc1}"
CAPACITY="${CAPACITY:-4000000000}"
KEY_NAME="${KEY_NAME:-${BUCKET}-key}"
WEBUI_USER="${WEBUI_USER:-admin}"
NODE_ID="${NODE_ID:-}"

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "CHYBA: chybi $dep" >&2; exit 1; }
done
[ -n "$WEBUI_URL" ] || { echo "CHYBA: nastav WEBUI_URL" >&2; exit 1; }
[ -n "$S3_URL" ]    || { echo "CHYBA: nastav S3_URL" >&2; exit 1; }

API="${WEBUI_URL%/}/api"
S3="${S3_URL%/}"
JAR="$(mktemp -t garagejar)"
TMP="$(mktemp -d -t garagetest)"
trap 'rm -rf "$JAR" "$TMP"' EXIT

say () { printf '\n==> %s\n' "$1"; }
ok  () { printf '    OK %s\n' "${1:-}"; }
die () { printf '    SELHALO: %s\n' "$1" >&2; exit 1; }

# curl pres webui proxy, vraci telo; kod si sahni do $HTTP_CODE
call () { # call METHOD PATH [JSON_BODY]
  local m="$1" p="$2" b="${3:-}" out
  if [ -n "$b" ]; then
    out=$(curl -sS -b "$JAR" -w '\n%{http_code}' -X "$m" "$API$p" \
          -H 'Content-Type: application/json' -d "$b")
  else
    out=$(curl -sS -b "$JAR" -w '\n%{http_code}' -X "$m" "$API$p")
  fi
  HTTP_CODE="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
}

# ---------------------------------------------------------------- prihlaseni
say "Prihlaseni"
call GET /auth/status >/dev/null
if [ "$HTTP_CODE" = "401" ]; then
  read -rp "    Uzivatel [$WEBUI_USER]: " u; WEBUI_USER="${u:-$WEBUI_USER}"
  read -rsp "    Heslo: " p; echo
  body=$(jq -n --arg u "$WEBUI_USER" --arg p "$p" '{username:$u,password:$p}')
  unset p
  resp=$(curl -sS -c "$JAR" -X POST "$API/auth/login" -H 'Content-Type: application/json' -d "$body")
  echo "$resp" | jq -e '.authenticated == true' >/dev/null || die "prihlaseni: $resp"
  ok "prihlasen jako $WEBUI_USER"
elif [ "$HTTP_CODE" = "200" ]; then
  echo "    VAROVANI: webui je bez hesla (AUTH_USER_PASS neni nastaveno)."
  echo "    Kdokoli na internetu muze cist secret klice pres /api/v2/GetKeyInfo?showSecretKey=true."
  read -rp "    Pokracovat presto? [a/N]: " a
  [ "$a" = "a" ] || exit 1
else
  die "neocekavany kod $HTTP_CODE z /auth/status"
fi

# ------------------------------------------------------------------- layout
say "Kontrola layoutu"
layout=$(call GET /v2/GetClusterLayout)
[ "$HTTP_CODE" = "200" ] || die "GetClusterLayout: $layout"
lver=$(echo "$layout" | jq -r '.version')
lroles=$(echo "$layout" | jq -r '.roles | length')

if [ "$lroles" -gt 0 ]; then
  ok "layout uz je nastaveny (verze $lver, $lroles uzlu) - preskakuji"
else
  status=$(call GET /v2/GetClusterStatus)
  [ "$HTTP_CODE" = "200" ] || die "GetClusterStatus: $status"
  if [ -z "$NODE_ID" ]; then
    n=$(echo "$status" | jq -r '.nodes | length')
    [ "$n" = "1" ] || die "v clusteru je $n uzlu, urci ktery chces pres NODE_ID="
    NODE_ID=$(echo "$status" | jq -r '.nodes[0].id')
  fi
  avail=$(echo "$status" | jq -r --arg id "$NODE_ID" \
          '.nodes[] | select(.id==$id) | .dataPartition.available')
  echo "    uzel:     $NODE_ID"
  echo "    volne:    $((avail/1000/1000/1000)) GB na datovem oddilu"
  echo "    priradim: zona '$ZONE', kapacita $((CAPACITY/1000/1000/1000)) GB"
  if [ "$CAPACITY" -gt "$avail" ]; then
    echo "    VAROVANI: kapacita je vetsi nez volne misto. Metadata sdili stejny oddil."
  fi
  read -rp "    Aplikovat layout? [a/N]: " a
  [ "$a" = "a" ] || die "zruseno uzivatelem"

  body=$(jq -n --arg id "$NODE_ID" --arg z "$ZONE" --argjson c "$CAPACITY" \
         '{parameters:null,roles:[{id:$id,zone:$z,capacity:$c,tags:[]}]}')
  call POST /v2/UpdateClusterLayout "$body" >/dev/null
  [ "$HTTP_CODE" = "200" ] || die "UpdateClusterLayout skoncil s $HTTP_CODE"

  applied=$(call POST /v2/ApplyClusterLayout "$(jq -n --argjson v "$((lver+1))" '{version:$v}')")
  [ "$HTTP_CODE" = "200" ] || die "ApplyClusterLayout: $applied
Nejcastejsi pricina: replication_factor v garage.toml je vyssi nez pocet uzlu."
  echo "$applied" | jq -r '.message[]' | sed 's/^/    | /'
  ok
fi

say "Zdravi clusteru"
for _ in $(seq 1 15); do
  h=$(call GET /v2/GetClusterHealth)
  st=$(echo "$h" | jq -r '.status')
  [ "$st" = "healthy" ] && break
  sleep 2
done
[ "$st" = "healthy" ] || die "cluster hlasi '$st': $h"
ok "$(echo "$h" | jq -r '"storageNodes=\(.storageNodes) quorum=\(.partitionsQuorum)/\(.partitions)"')"

# ------------------------------------------------------------------- bucket
say "Bucket '$BUCKET'"
info=$(call GET "/v2/GetBucketInfo?globalAlias=$BUCKET")
if [ "$HTTP_CODE" = "200" ]; then
  BUCKET_ID=$(echo "$info" | jq -r '.id')
  ok "uz existuje ($BUCKET_ID)"
else
  created=$(call POST /v2/CreateBucket "$(jq -n --arg a "$BUCKET" '{globalAlias:$a}')")
  [ "$HTTP_CODE" = "200" ] || die "CreateBucket: $created"
  BUCKET_ID=$(echo "$created" | jq -r '.id')
  ok "vytvoren ($BUCKET_ID)"
fi

# --------------------------------------------------------------------- klic
say "Access key '$KEY_NAME'"
key=$(call POST /v2/CreateKey "$(jq -n --arg n "$KEY_NAME" '{name:$n}')")
[ "$HTTP_CODE" = "200" ] || die "CreateKey: $key"
AKID=$(echo "$key" | jq -re '.accessKeyId')
SECRET=$(echo "$key" | jq -re '.secretAccessKey')
ok "$AKID"

perm=$(jq -n --arg b "$BUCKET_ID" --arg k "$AKID" \
       '{bucketId:$b,accessKeyId:$k,permissions:{read:true,write:true,owner:true}}')
call POST /v2/AllowBucketKey "$perm" >/dev/null
[ "$HTTP_CODE" = "200" ] || die "AllowBucketKey skoncil s $HTTP_CODE"
ok "prava read+write+owner na '$BUCKET'"

# ------------------------------------------------------------------ overeni
SIG=(--aws-sigv4 "aws:amz:${REGION}:s3" --user "${AKID}:${SECRET}")
echo "hello garage $(date -u +%FT%TZ)" > "$TMP/hello.txt"

say "TEST 1/4 PUT"
c=$(curl -sS -o /dev/null -w '%{http_code}' "${SIG[@]}" -X PUT "$S3/$BUCKET/hello.txt" --data-binary @"$TMP/hello.txt")
[ "$c" = "200" ] && ok "($c)" || die "PUT vratil $c"

say "TEST 2/4 GET"
curl -sS "${SIG[@]}" "$S3/$BUCKET/hello.txt" -o "$TMP/back.txt"
diff -q "$TMP/hello.txt" "$TMP/back.txt" >/dev/null && ok "obsah sedi" || die "stazeny obsah nesouhlasi"

say "TEST 3/4 ListObjects"
curl -sS "${SIG[@]}" "$S3/$BUCKET/?list-type=2" | grep -q "hello.txt" && ok || die "objekt neni ve vypisu"

say "TEST 4/4 DELETE"
c=$(curl -sS -o /dev/null -w '%{http_code}' "${SIG[@]}" -X DELETE "$S3/$BUCKET/hello.txt")
[ "$c" = "204" ] && ok "($c)" || die "DELETE vratil $c"

cat <<EOF

========================================
 VSECHNY TESTY PROSLY. Bucket je funkcni.
========================================

AWS_ACCESS_KEY_ID     = $AKID
AWS_SECRET_ACCESS_KEY = $SECRET
Endpoint              = $S3
Region                = $REGION
Bucket                = $BUCKET

--- ~/.aws/credentials -------------------
[$BUCKET]
aws_access_key_id = $AKID
aws_secret_access_key = $SECRET

--- ~/.aws/config ------------------------
[profile $BUCKET]
region = $REGION
s3 =
    addressing_style = path
services = ${BUCKET}-svc

[services ${BUCKET}-svc]
s3 =
    endpoint_url = $S3

--- pouziti ------------------------------
aws --profile $BUCKET s3 ls s3://$BUCKET/
EOF
