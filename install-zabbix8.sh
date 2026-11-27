#!/usr/bin/env bash
# Instalace Zabbix 8.0 LTS (server, frontend, Apache, agent 2) a MariaDB na Debian 13.
# Jen balicky - nastaveni dela configure-zabbix8.sh. Opakovane spusteni nic neznici.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ZBX_VER="8.0"

log() { echo "==> $*"; }
die() { echo "CHYBA: $*" >&2; exit 1; }

log "Priprava systemu"
apt-get update -y
apt-get install -y wget curl jq ca-certificates

# Oficialni repozitar Zabbix 8.0 (ne balicky z repozitare Debianu)
if ! grep -rqs "zabbix/${ZBX_VER}/" /etc/apt/sources.list.d/ 2>/dev/null; then
  log "Pridavam repozitar Zabbix ${ZBX_VER}"
  BASE_URL="https://repo.zabbix.com/zabbix/${ZBX_VER}/release/debian/pool/main/z/zabbix-release"
  REPO_DEB=""
  # prvni nazev je overeny, druhy je zaloha
  for name in "zabbix-release_latest_${ZBX_VER}+debian13_all.deb" "zabbix-release_latest+debian13_all.deb"; do
    if wget -q -O "/tmp/${name}" "${BASE_URL}/${name}"; then REPO_DEB="/tmp/${name}"; break; fi
    rm -f "/tmp/${name}"
  done
  [ -n "$REPO_DEB" ] || die "Nepodarilo se stahnout repozitarni balicek Zabbix ${ZBX_VER} pro Debian 13."
  rm -f /etc/apt/sources.list.d/zabbix.list
  dpkg -i --force-confnew "$REPO_DEB"
  apt-get update -y
fi

log "Instalace balicku (MariaDB, Zabbix server, frontend, Apache, agent 2)"
apt-get install -y mariadb-server \
  zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2

VER="$(dpkg-query -W -f='${Version}' zabbix-server-mysql)"
case "$VER" in
  [0-9]:${ZBX_VER}.*|${ZBX_VER}.*) log "Nainstalovan zabbix-server-mysql ${VER}" ;;
  *) die "Nainstalovana verze ${VER} neni ${ZBX_VER} - zkontrolujte repozitar." ;;
esac

systemctl enable --now mariadb

log "Instalace Zabbixu ${ZBX_VER} hotova."
