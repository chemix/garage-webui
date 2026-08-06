# VHS: nasazení Garage + garage-webui v Dokploy

Provozní poznámky k nasazení [Garage](https://garagehq.deuxfleurs.fr/) (S3-kompatibilní úložiště)
a jeho webového administračního rozhraní na infrastruktuře Váš Hosting.

Upstream README popisuje aplikaci obecně. Tenhle dokument řeší jen to, co je specifické pro
naše nasazení: proměnné prostředí, kroky po deployi a chyby, na které jsme reálně narazili.

> Dokument je záměrně bez konkrétních adres a hostitelů. Údaje o konkrétní instalaci si veď
> mimo repozitář — v Dokploy u dané služby nebo v interní evidenci.

---

## Architektura

Dva kontejnery, oba za Traefikem s automatickým TLS:

| Služba | Port | Veřejná doména | Účel |
|---|---|---|---|
| `garage` | 3900 | S3 doména | S3 API — data |
| `garage` | 3903 | admin doména | Admin API — správa clusteru |
| `webui` | 3909 | doména administrace | Administrační GUI |

Pokud domény negeneruješ ručně, Dokploy je odvodí ve tvaru `<sluzba>-<hash>.<ip>.sslip.io`.

Admin API na veřejné doméně **není nutné**. Pokud webui běží na stejném hostu, nastav
`API_BASE_URL` na interní adresu v Docker síti (`http://<sluzba>:3903`) a Traefik routu smaž —
zmenšíš tím útočnou plochu.

---

## Proměnné prostředí

Nastavují se v Dokploy → *Environment* u služby `webui`. Aplikace je čte přes `godotenv` při
startu, konfigurační soubor `garage.toml` v kontejneru webui namountovaný mít nemusíš.

| Proměnná | Povinná | Popis |
|---|---|---|
| `API_BASE_URL` | ano | Adresa Garage admin API. **Bez lomítka na konci** — kód skládá URL jako `endpoint + "/v2/…"`. |
| `API_ADMIN_KEY` | ano | Hodnota `admin_token` ze sekce `[admin]` v `garage.toml`. |
| `S3_ENDPOINT_URL` | ano | Adresa S3 API. Bez ní nefunguje prohlížeč objektů. |
| `AUTH_USER_PASS` | ano | `uzivatel:bcrypt_hash`. Viz níže. |
| `S3_REGION` | ne | Default `garage`. Musí sedět s `s3_region` v `garage.toml`. |
| `CONFIG_PATH` | ne | Cesta ke `garage.toml`. Default `/etc/garage.toml`. |
| `BASE_PATH` | ne | Prefix, když UI běží v podadresáři. |

Šablona:

```
API_BASE_URL=<<ADDRESS>>
API_ADMIN_KEY=<<KEY>>
S3_ENDPOINT_URL=<<ADDRESS>>
AUTH_USER_PASS=<<USER>>:<<BCRYPT_HASH>>
```

`API_BASE_URL` a `API_ADMIN_KEY` mají přednost před hodnotami z `garage.toml`
(`backend/utils/garage.go:44` a `:88`), takže konfiguraci můžeš řídit výhradně přes ENV.

### AUTH_USER_PASS

**Bez téhle proměnné je webui zcela nechráněné.** Autentizační middleware pouští všechny
požadavky dál (`backend/middleware/auth.go:16`) a `/api/*` proxuje na admin API i s tvým tokenem
(`backend/router/router.go:32`). Kdokoli na internetu pak může vytvářet klíče, mazat buckety
a číst secret klíče přes `GET /api/v2/GetKeyInfo?showSecretKey=true`.

```sh
./scripts/garage-auth-hash.sh admin
```

Skript se interaktivně zeptá na heslo (neukládá ho do historie shellu ani ho nedává do `ps`)
a vypíše hotovou hodnotu.

#### Bez skriptu, přímo na příkazové řádce

Když nemáš repozitář po ruce (typicky při práci přímo na serveru), stačí `htpasswd`
z balíčku `apache2-utils`. Bez `-b` se na heslo doptá a neechuje ho, takže neskončí
v historii shellu ani v `ps`:

```sh
htpasswd -nBC 10 admin
```

Vypíše rovnou celý řádek `admin:$2y$10$…`, který je hodnotou `AUTH_USER_PASS`.
`-n` znamená vypsat na stdout místo zápisu do souboru, `-B` bcrypt, `-C 10` cost faktor.

Jednořádkově, ale s heslem v historii i v `ps` — použij jen když ti to nevadí:

```sh
htpasswd -nbBC 10 admin 'HESLO'
```

Když `htpasswd` na stroji není a nechceš nic instalovat:

```sh
docker run --rm -it httpd:alpine htpasswd -nBC 10 admin
```

Na co pozor:

- **Musí to být bcrypt** (`htpasswd -B`). Ověřuje se přes `golang.org/x/crypto/bcrypt`
  (`backend/router/auth.go:31`), takže `openssl passwd` ani `htpasswd -m` nefungují.
  Správný hash začíná `$2y$` nebo `$2a$`.
- **Uživatelské jméno nesmí obsahovat dvojtečku** — kód dělá `strings.Split(…, ":")`
  a bere `[0]` jako jméno, `[1]` jako hash.
- **V Dokploy Environment `$` nezdvojuj.** Zdvojení na `$$` platí jen v `docker-compose.yml`,
  kde by je jinak Compose sežral jako interpolaci proměnných.

Ověření po redeployi — musí vrátit `401`:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://<webui>/api/auth/status
```

---

## Kroky po nasazení

**Samotný deploy nestačí.** Čerstvý Garage nemá přiřazený layout, takže nemá žádný úložný
prostor — `/api/buckets` vrací `500 Internal error: Layout not ready` a `/health` hlásí
`503 Quorum is not available`. Uzel musí dostat zónu a kapacitu a layout se musí commitnout.

Všechno dokončí jeden skript — přiřadí layout, počká na `healthy`, vytvoří bucket, vyrobí
access key, napojí ho a nakonec ověří reálným S3 přenosem (PUT → GET s porovnáním obsahu →
ListObjects → DELETE):

```sh
WEBUI_URL=https://<webui> \
S3_URL=https://<s3-endpoint> \
BUCKET=test \
./scripts/garage-setup.sh
```

Volitelně `REGION`, `ZONE`, `CAPACITY`, `KEY_NAME`, `WEBUI_USER`, `NODE_ID`.
Skript je idempotentní v tom smyslu, že hotový layout i existující bucket přeskočí;
access key vytváří pokaždé nový.

Kapacitu volí člověk, ne skript: **data i metadata sdílí stejný diskový oddíl**, takže při
zaplnění nespadne jen upload, ale i databáze metadat. Nech rezervu.

Ruční varianta, kdyby bylo potřeba jen layout:

```sh
garage layout assign <node-id> -z dc1 -c 4G
garage layout apply --version 1
```

---

## Konfigurace klientů

Region je `garage` (ne `us-east-1`) a **adresování musí být path-style**. Virtual-host styl
(`bucket.<s3-endpoint>`) Garage zvládne jen s nastaveným `root_domain` v sekci `[s3_api]`,
což u nás nastavené není.

**AWS CLI** — `~/.aws/config`:

```ini
[profile garage]
region = garage
s3 =
    addressing_style = path
services = garage-svc

[services garage-svc]
s3 =
    endpoint_url = https://<s3-endpoint>
```

**Cyberduck** — použij připravený profil `scripts/Garage.cyberduckprofile` (dvojklik ho
naimportuje), ne generický „Amazon S3". Profil napevno nastavuje `Region = garage` a
`s3.bucket.virtualhost.disable=true`; adresu serveru zadáš v záložce.

**curl** — pro rychlý test bez instalace čehokoli:

```sh
curl --aws-sigv4 "aws:amz:garage:s3" --user "$AKID:$SECRET" https://<s3-endpoint>/<bucket>/?list-type=2
```

---

## Řešení problémů

Chybové hlášky, na které jsme narazili, a co reálně znamenají:

| Hláška | Kde | Příčina |
|---|---|---|
| `Internal error: Layout not ready` | `/api/buckets` | Layout není přiřazený. Viz kroky po nasazení. |
| `Quorum is not available for some/all partitions` | `/health` | Totéž — cluster nemá storage uzly. |
| `Forbidden: No such key: <x>` | S3 | Server nezná access key `<x>`. Sedí ten, co klient posílá? |
| `Forbidden: Invalid signature` | S3 | Klíč existuje, nesedí secret. |
| `unexpected scope: <datum>/<region>/s3/…` | S3 | Klient podepisuje špatným regionem. Musí být `garage`. |
| `Bad request: Unknown API endpoint: GET /` | admin API | Normální odpověď admin API na kořen — endpoint žije. |
| `unauthorized` (401) | `/api/*` | Chybí přihlášení. Očekávaný stav, když je `AUTH_USER_PASS` nastavené. |
| `AccessDenied … anonymous access` | S3 | Normální odpověď na nepodepsaný požadavek — endpoint žije. |

Diagnostika bez znalosti secret klíče — pošli falešný podpis a čti, na co si server stěžuje:

```sh
curl -sS https://<s3-endpoint>/ \
  -H "Authorization: AWS4-HMAC-SHA256 Credential=<AKID>/20260101/garage/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=dead" \
  -H "x-amz-date: 20260101T000000Z" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD"
```

`Invalid signature` znamená, že klíč i region jsou v pořádku a chyba je jinde.

### Cyberduck cachuje credentials v Klíčence

Cyberduck drží uživatelské jméno i heslo v macOS Klíčence klíčované hostitelem. **Přepsání
pole v záložce se nemusí projevit** — GUI ukazuje novou hodnotu, ale podepisuje se starou.
Projeví se to jako nevysvětlitelný `403 No such key: <stará hodnota>`.

Řešení: smaž záložku, v *Klíčence* najdi hostitele a smaž i tamní záznamy, pak vytvoř znovu.
Skutečně odeslaný požadavek ukáže log drawer (⌘L) — řádek `Authorization: … Credential=…`.

---

## Bezpečnostní kontrolní seznam

- [ ] `AUTH_USER_PASS` nastavené, `/api/auth/status` bez přihlášení vrací `401`
- [ ] Admin API sundané z veřejné domény, `API_BASE_URL` míří na interní adresu
- [ ] V sekci Keys nejsou klíče, které tam nepatří
- [ ] `replication_factor` odpovídá počtu uzlů — při `1` neexistuje žádná redundance
  a ztráta disku znamená ztrátu dat
- [ ] Kapacita layoutu má rezervu vůči volnému místu

---

## Šablona evidence nasazení

Vyplněnou verzi drž mimo repozitář.

| Položka | Hodnota |
|---|---|
| Server | `<<HOSTNAME>>` |
| Má VPS Centrum? | ano / ne — pokud ne, veškerá správa jde jen přes HTTP API, k souborům se nedostaneš |
| Orchestrace | Dokploy |
| Verze Garage | `<<VERZE>>` |
| Počet uzlů / `replication_factor` | `<<N>>` / `<<RF>>` |
| Doména administrace | `<<ADDRESS>>` |
| S3 doména | `<<ADDRESS>>` |
| Admin doména | `<<ADDRESS>>` nebo interní |
| Layout | verze `<<V>>`, zóna `<<ZONA>>`, kapacita `<<KAPACITA>>` |
| Buckety | `<<SEZNAM>>` |
| Zprovozněno | `<<DATUM>>` |
