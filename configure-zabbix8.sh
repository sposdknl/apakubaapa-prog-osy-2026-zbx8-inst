#!/usr/bin/env bash
# Konfigurace Zabbix 8.0: databaze, hesla, zabbix.conf.php, agent 2, sluzby,
# prvotni nastaveni pres API (lokalni host, host sposdk.cz).
# Spoustet az po install-zabbix8.sh. Opakovane spusteni databazi neznici.
set -euo pipefail

ZBX_VER="8.0"
SECRETS="/root/zabbix-secrets.env"
DB_NAME="zabbix"
DB_USER="zabbix"
LOCAL_HOSTNAME="debian13-local"
# Kde hledat export hosta sposdk.cz (slozka projektu je ve VM sdilena jako /vagrant)
EXPORT_DIRS=("/vagrant/Zabbix/export" "/vagrant/export" "/tmp/export")

log()  { echo "==> $*"; }
warn() { echo "VAROVANI: $*" >&2; }
die()  { echo "CHYBA: $*" >&2; exit 1; }
gen()  { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

dpkg -s zabbix-server-mysql >/dev/null 2>&1 || die "Zabbix neni nainstalovan. Nejdriv spust install-zabbix8.sh."
DB_CLI="mariadb"; command -v mariadb >/dev/null 2>&1 || DB_CLI="mysql"

# ---------------------------------------------------------------- hesla
# Heslo k databazi se nikdy neuklada do repozitare. Bud prijde z promenne prostredi
# hostitele (ZBX_DB_PASSWORD), nebo se pri prvnim behu nahodne vygeneruje a ulozi
# jen uvnitr VM do /root/zabbix-secrets.env (600).
# Heslo weboveho uzivatele Admin se NEMENI (vychozi Zabbix heslo "zabbix").
if [ -f "$SECRETS" ]; then
  # shellcheck disable=SC1090
  . "$SECRETS"
fi
DB_PASS="${ZBX_DB_PASSWORD:-${DB_PASS:-$(gen)}}"
SERVER_NAME="${ZBX_SERVER_NAME:-Zabbix 8 - brichacek}"

[[ "$DB_PASS" =~ ^[A-Za-z0-9]+$ ]]    || die "ZBX_DB_PASSWORD smi obsahovat jen znaky A-Z a-z 0-9."
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9\ ._-]+$ ]] || die "ZBX_SERVER_NAME smi obsahovat jen pismena, cisla, mezeru, '.', '_' a '-'."

umask 077
cat > "$SECRETS" <<EOF
DB_PASS=${DB_PASS}
EOF
chmod 600 "$SECRETS"
umask 022

# ---------------------------------------------------------------- databaze
log "Databaze ${DB_NAME} a uzivatel ${DB_USER}"
# Heslo jde pres stdin (heredoc), takze se neobjevi v seznamu procesu.
"$DB_CLI" <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

HAS_SCHEMA="$("$DB_CLI" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='users'")"
if [ "$HAS_SCHEMA" = "0" ]; then
  log "Import pocatecniho schematu a dat (jednorazove)"
  SQL_GZ="$(find /usr/share/zabbix* -name server.sql.gz -print -quit 2>/dev/null || true)"
  [ -n "$SQL_GZ" ] || die "Soubor server.sql.gz nenalezen (balicek zabbix-sql-scripts)."
  "$DB_CLI" -e "SET GLOBAL log_bin_trust_function_creators = 1;"
  zcat "$SQL_GZ" | "$DB_CLI" --default-character-set=utf8mb4 "$DB_NAME"
  "$DB_CLI" -e "SET GLOBAL log_bin_trust_function_creators = 0;"
else
  log "Schema uz v databazi existuje - import preskocen"
fi

# ---------------------------------------------------------------- konfigurace
set_param() { # soubor klic hodnota
  local file="$1" key="$2" value="$3"
  if grep -qE "^[#[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

log "Konfigurace Zabbix serveru"
ZS_CONF="/etc/zabbix/zabbix_server.conf"
set_param "$ZS_CONF" DBName "$DB_NAME"
set_param "$ZS_CONF" DBUser "$DB_USER"
set_param "$ZS_CONF" DBPassword "$DB_PASS"
chown root:zabbix "$ZS_CONF"; chmod 640 "$ZS_CONF"

log "Konfigurace webu (zabbix.conf.php - PHP wizard neni potreba)"
mkdir -p /etc/zabbix/web
WEB_CONF="/etc/zabbix/web/zabbix.conf.php"
read -r -d '' WEB_TPL <<'PHP' || true
<?php
// Generovano provisioningem - needitovat rucne.
$DB['TYPE']     = 'MYSQL';
$DB['SERVER']   = 'localhost';
$DB['PORT']     = '0';
$DB['DATABASE'] = '__DB_NAME__';
$DB['USER']     = '__DB_USER__';
$DB['PASSWORD'] = '__DB_PASS__';
$DB['SCHEMA']   = '';
$DB['ENCRYPTION'] = false;
$DB['KEY_FILE']   = '';
$DB['CERT_FILE']  = '';
$DB['CA_FILE']    = '';
$DB['VERIFY_HOST'] = false;
$DB['CIPHER_LIST'] = '';
$DB['VAULT'] = '';
$DB['VAULT_URL'] = '';
$DB['VAULT_DB_PATH'] = '';
$DB['VAULT_TOKEN'] = '';
$DB['VAULT_CERT_FILE'] = '';
$DB['VAULT_KEY_FILE'] = '';
$DB['VAULT_PREFIX'] = '';
$DB['DOUBLE_IEEE754'] = true;

$ZBX_SERVER      = 'localhost';
$ZBX_SERVER_PORT = '10051';
$ZBX_SERVER_NAME = '__SERVER_NAME__';

$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP
shopt -u patsub_replacement 2>/dev/null || true
WEB_TPL="${WEB_TPL//__DB_NAME__/$DB_NAME}"
WEB_TPL="${WEB_TPL//__DB_USER__/$DB_USER}"
WEB_TPL="${WEB_TPL//__DB_PASS__/$DB_PASS}"
WEB_TPL="${WEB_TPL//__SERVER_NAME__/$SERVER_NAME}"
umask 027
printf '%s\n' "$WEB_TPL" > "$WEB_CONF"
umask 022
chown www-data:www-data "$WEB_CONF"; chmod 640 "$WEB_CONF"

# Presmerovani korene webu na /zabbix, aby stacilo http://127.0.0.1:8080/
cat > /etc/apache2/conf-available/zabbix-root-redirect.conf <<'EOF'
RedirectMatch ^/$ /zabbix/
EOF
a2enconf zabbix >/dev/null 2>&1 || true
a2enconf zabbix-root-redirect >/dev/null

log "Konfigurace Zabbix Agent 2"
ZA_CONF="/etc/zabbix/zabbix_agent2.conf"
set_param "$ZA_CONF" Server "127.0.0.1,::1"
set_param "$ZA_CONF" ServerActive "127.0.0.1"
set_param "$ZA_CONF" Hostname "$LOCAL_HOSTNAME"

# ---------------------------------------------------------------- sluzby
log "Spusteni a povoleni sluzeb"
systemctl enable mariadb zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 apache2

log "Cekam na webove rozhrani"
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null http://127.0.0.1/zabbix/index.php; then break; fi
  sleep 2
done
curl -fsS -o /dev/null http://127.0.0.1/zabbix/index.php || die "Web Zabbixu neodpovida."

# ---------------------------------------------------------------- monitoring pres API
API_URL="http://127.0.0.1/zabbix/api_jsonrpc.php"
TOKEN=""

# api METODA PARAMS_JSON  -> vypise .result, pri chybe vrati nenulovy kod
api() {
  local method="$1" params="$2" resp
  local -a hdr=()
  [ -n "$TOKEN" ] && hdr=(-H "Authorization: Bearer ${TOKEN}")
  resp="$(curl -fsS "${hdr[@]}" -H 'Content-Type: application/json-rpc' \
    -d "$(jq -cn --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')" \
    "$API_URL")" || return 1
  if [ "$(jq 'has("error")' <<<"$resp")" = "true" ]; then
    echo "API ${method}: $(jq -c .error <<<"$resp")" >&2
    return 1
  fi
  jq -c .result <<<"$resp"
}

# login HESLO -> nastavi TOKEN
login() {
  local res
  res="$(api user.login "$(jq -cn --arg pw "$1" '{username:"Admin",password:$pw}')" 2>/dev/null)" || return 1
  TOKEN="$(jq -r . <<<"$res")"
}

# ---------------------------------------------------------------- prihlaseni do API
# Heslo Admina se nemeni. Pro API se pouzije vychozi "zabbix"
# (nebo ZBX_ADMIN_PASSWORD, kdyz uz je heslo rucne zmenene).
if ! login "${ZBX_ADMIN_PASSWORD:-zabbix}"; then
  echo "Posledni odpoved API:" >&2
  api user.login "$(jq -cn --arg pw "${ZBX_ADMIN_PASSWORD:-zabbix}" '{username:"Admin",password:$pw}')" >&2 || true
  die "Nelze se prihlasit do Zabbix API (uzivatel Admin). Pokud jsi heslo zmenil, predej ho promennou ZBX_ADMIN_PASSWORD."
fi
log "Prihlaseni do API uspesne"

# ---------------------------------------------------------------- lokalni host
if [ "$(api host.get "$(jq -cn --arg h "$LOCAL_HOSTNAME" '{filter:{host:[$h]},output:["hostid"]}')" | jq 'length')" = "0" ]; then
  log "Pridavam lokalniho hosta ${LOCAL_HOSTNAME}"
  GROUP_ID="$(api hostgroup.get '{"filter":{"name":["Linux servers"]},"output":["groupid"]}' | jq -r '.[0].groupid')"
  TPL_JSON="$(api template.get '{"filter":{"host":["Linux by Zabbix agent"]},"output":["templateid"]}')"
  [ "$(jq length <<<"$TPL_JSON")" != "0" ] || die "Sablona 'Linux by Zabbix agent' nenalezena."
  PARAMS="$(jq -cn --arg h "$LOCAL_HOSTNAME" --arg g "$GROUP_ID" --argjson t "$TPL_JSON" '{
      host:$h, name:$h,
      interfaces:[{type:1,main:1,useip:1,ip:"127.0.0.1",dns:"",port:"10050"}],
      groups:[{groupid:$g}],
      templates:$t}')"
  api host.create "$PARAMS" >/dev/null
else
  log "Host ${LOCAL_HOSTNAME} uz existuje"
fi

# ---------------------------------------------------------------- host sposdk.cz
if [ "$(api host.get '{"filter":{"host":["sposdk.cz"]},"output":["hostid"]}' | jq 'length')" != "0" ]; then
  log "Host sposdk.cz uz existuje"
else
  IMPORTED=0
  IMPORT_FILE=""
  for d in "${EXPORT_DIRS[@]}"; do
    [ -d "$d" ] || continue
    # prvni soubor (yaml/yml/xml/json), ve kterem se vyskytuje sposdk.cz
    IMPORT_FILE="$(grep -rlsF 'sposdk.cz' --include='*.yaml' --include='*.yml' --include='*.xml' --include='*.json' "$d" | sort | head -n1 || true)"
    [ -n "$IMPORT_FILE" ] && break
  done
  if [ -n "$IMPORT_FILE" ]; then
    case "${IMPORT_FILE##*.}" in yml|yaml) FMT=yaml ;; xml) FMT=xml ;; json) FMT=json ;; esac
    log "Import hosta sposdk.cz ze souboru $(basename "$IMPORT_FILE")"
    PARAMS="$(jq -cn --arg fmt "$FMT" --rawfile src "$IMPORT_FILE" '{
      format:$fmt, source:$src,
      rules:{
        host_groups:{createMissing:true,updateExisting:true},
        template_groups:{createMissing:true,updateExisting:true},
        hosts:{createMissing:true,updateExisting:true},
        templates:{createMissing:true,updateExisting:true},
        templateLinkage:{createMissing:true},
        items:{createMissing:true,updateExisting:true},
        triggers:{createMissing:true,updateExisting:true},
        graphs:{createMissing:true,updateExisting:true},
        discoveryRules:{createMissing:true,updateExisting:true},
        httptests:{createMissing:true,updateExisting:true},
        valueMaps:{createMissing:true,updateExisting:true}}}')"
    if api configuration.import "$PARAMS" >/dev/null; then
      IMPORTED=1
    else
      warn "Import selhal (viz chyba vyse) - pouziji nahradni vytvoreni hosta pres API."
    fi
  else
    warn "Export hosta sposdk.cz nenalezen (Zabbix/export) - pouziji nahradni vytvoreni hosta pres API."
  fi

  if [ "$IMPORTED" = "0" ]; then
    GROUP_ID="$(api hostgroup.get '{"filter":{"name":["Linux servers"]},"output":["groupid"]}' | jq -r '.[0].groupid')"
    TPL_JSON="$(api template.get '{"filter":{"host":["Website certificate by Zabbix agent 2"]},"output":["templateid"]}')"
    [ "$(jq length <<<"$TPL_JSON")" != "0" ] || die "Sablona 'Website certificate by Zabbix agent 2' nenalezena."
    PARAMS="$(jq -cn --arg g "$GROUP_ID" --argjson t "$TPL_JSON" '{
      host:"sposdk.cz", name:"sposdk.cz",
      interfaces:[{type:1,main:1,useip:1,ip:"127.0.0.1",dns:"",port:"10050"}],
      groups:[{groupid:$g}],
      templates:$t,
      macros:[{macro:"{$CERT.WEBSITE.HOSTNAME}",value:"sposdk.cz"}]}')"
    api host.create "$PARAMS" >/dev/null
    log "Host sposdk.cz vytvoren pres API (sablona Website certificate by Zabbix agent 2)"
  fi
fi

log "Nastaveni monitoringu dokonceno"

# ---------------------------------------------------------------- kontrola
log "Stav sluzeb"
for s in mariadb zabbix-server zabbix-agent2 apache2; do
  printf '%-16s %s\n' "$s" "$(systemctl is-active "$s")"
  systemctl is-active --quiet "$s" || die "Sluzba $s nebezi."
done

cat <<EOF

Hotovo. Web: http://127.0.0.1:8080/zabbix/   (uzivatel Admin, vychozi heslo Zabbixu)
Heslo k databazi je ve VM v ${SECRETS}:
  vagrant ssh -c "sudo cat ${SECRETS}"
EOF
