#!/bin/bash

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Uso: $0 [--dry-run]"
      echo "  --dry-run  Simula a migracao sem executar comandos nem alterar arquivos."
      exit 0
      ;;
  esac
done

LOG="/var/log/samba-ad-migration.log"
# /var/log exige root; cai para um arquivo local para permitir --dry-run sem root.
if ! ( : >> "$LOG" ) 2>/dev/null; then
  LOG="./samba-ad-migration.log"
fi
exec > >(tee -a "$LOG") 2>&1

echo "==== MIGRAÇÃO SAMBA AD ===="
[ "$DRY_RUN" -eq 1 ] && echo "*** MODO DRY-RUN (simulacao, sem alteracoes) ***"

# A migracao real altera /etc, instala pacotes e gerencia servicos: exige root.
# O modo --dry-run nao toca no sistema, entao dispensa root.
require_root() {
  if [ "$DRY_RUN" -ne 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "❌ Este script precisa ser executado como root (use: sudo $0)."
    exit 1
  fi
}

# Executa um comando, ou apenas o exibe em modo dry-run.
run() {
  echo ">> $*"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [DRY-RUN] comando nao executado"
    return 0
  fi
  "$@"
}

# Grava o conteudo recebido via stdin em um arquivo, ou apenas o exibe em dry-run.
write_file() {
  local path="$1"
  local content
  content="$(cat)"
  echo ">> escrevendo $path"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [DRY-RUN] conteudo que seria gravado em $path:"
    printf '%s\n' "$content" | sed 's/^/   | /'
    return 0
  fi
  printf '%s\n' "$content" > "$path"
}

check_clock() {
  echo "⏱️  Verificando sincronizacao de relogio (NTP)..."
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    echo "   OK: relogio sincronizado via NTP."
    return 0
  fi
  echo "   ⚠️ Relogio NAO sincronizado por NTP. O Kerberos exige diferenca < 5 min;"
  echo "      sincronize com o mesmo servidor de tempo do AD antes de prosseguir."
  return 1
}

check_domain_reachable() {
  echo "🔎 Verificando registros SRV do dominio $1..."
  if host -t SRV "_ldap._tcp.$1" >/dev/null 2>&1; then
    echo "   OK: registros SRV _ldap._tcp encontrados."
    return 0
  fi
  echo "   ⚠️ Nao foi possivel resolver _ldap._tcp.$1. Confirme que o DNS aponta para o AD 2003."
  return 1
}

check_dns_consistency() {
  local host="$1" domain="$2" ip="$3"
  local fqdn="$host.$domain"
  echo "🌐 Verificando DNS direto/reverso de $fqdn ($ip)..."
  if getent hosts "$fqdn" | grep -qw "$ip"; then
    echo "   OK: $fqdn resolve para $ip."
  else
    echo "   ⚠️ $fqdn nao resolve para $ip."
  fi
  if getent hosts "$ip" | grep -qw "$fqdn"; then
    echo "   OK: reverso de $ip aponta para $fqdn."
  else
    echo "   ⚠️ Reverso de $ip nao aponta para $fqdn."
  fi
}

validate_prereqs() {
  # args: dominio realm host ip
  echo "===================================================="
  echo " VALIDACAO DE PRE-REQUISITOS"
  echo "===================================================="
  check_clock || true
  check_domain_reachable "$1" || true
  check_dns_consistency "$3" "$1" "$4" || true
  if [ "$2" != "$(echo "$2" | tr '[:lower:]' '[:upper:]')" ]; then
    echo "   ⚠️ O realm '$2' nao esta em MAIUSCULAS."
  fi
}

rollback() {
  echo "⚠️ Rollback..."
  run systemctl stop samba-ad-dc
  run rm -rf /var/lib/samba/*
}

require_root

read -p "Dominio: " DOMAIN
read -p "Realm: " REALM
read -p "Admin: " ADMIN
read -p "Hostname: " HOST
read -p "IP: " IP

validate_prereqs "$DOMAIN" "$REALM" "$HOST" "$IP"
read -p "Revise os avisos de pre-requisitos acima. Enter para continuar... " _

run apt update || rollback
run apt install -y samba krb5-user winbind smbclient dnsutils || rollback

run hostnamectl set-hostname "$HOST.$DOMAIN"

write_file /etc/hosts <<EOF
127.0.0.1 localhost
$IP $HOST.$DOMAIN $HOST
EOF

# O AD do Windows Server 2003 só oferece enctypes legados (RC4/DES). O krb5 do
# Debian Trixie desabilita crypto fraca por padrao, entao habilitamos esses
# enctypes (mantendo AES para o novo DC Samba e clientes modernos) para que o
# kinit e o "domain join" consigam negociar com o 2003.
ENCTYPES="aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 des-cbc-md5 des-cbc-crc"
write_file /etc/krb5.conf <<EOF
[libdefaults]
 default_realm = $REALM
 dns_lookup_realm = false
 dns_lookup_kdc = true
 allow_weak_crypto = true
 allow_rc4 = true
 allow_des3 = true
 default_tkt_enctypes = $ENCTYPES
 default_tgs_enctypes = $ENCTYPES
 permitted_enctypes = $ENCTYPES
EOF

run host -t SRV "_ldap._tcp.$DOMAIN" || rollback

run kinit "$ADMIN@$REALM" || rollback

run samba-tool domain join "$DOMAIN" DC -U"$ADMIN" --realm="$REALM" --dns-backend=SAMBA_INTERNAL || rollback

run systemctl enable samba-ad-dc
run systemctl restart samba-ad-dc

run samba-tool drs showrepl || rollback

run samba-tool ntacl sysvolcheck || run samba-tool ntacl sysvolreset

read -p "Transferir FSMO? (s/n): " FSMO
if [ "$FSMO" == "s" ]; then
  run samba-tool fsmo transfer --role=all
fi

echo "✅ Concluído"
