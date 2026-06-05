#!/bin/bash

LOG="/var/log/samba-ad-migration.log"

exec > >(tee -a $LOG) 2>&1

echo "==== MIGRAÇÃO SAMBA AD ===="

rollback() {
  echo "⚠️ Rollback..."
  systemctl stop samba-ad-dc
  rm -rf /var/lib/samba/*
}

read -p "Dominio: " DOMAIN
read -p "Realm: " REALM
read -p "Admin: " ADMIN
read -p "Hostname: " HOST
read -p "IP: " IP

apt update || rollback
apt install -y samba krb5-user winbind smbclient dnsutils || rollback

hostnamectl set-hostname $HOST.$DOMAIN

echo "127.0.0.1 localhost" > /etc/hosts
echo "$IP $HOST.$DOMAIN $HOST" >> /etc/hosts

# O AD do Windows Server 2003 só oferece enctypes legados (RC4/DES). O krb5 do
# Debian Trixie desabilita crypto fraca por padrao, entao habilitamos esses
# enctypes (mantendo AES para o novo DC Samba e clientes modernos) para que o
# kinit e o "domain join" consigam negociar com o 2003.
ENCTYPES="aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 des-cbc-md5 des-cbc-crc"
cat > /etc/krb5.conf <<EOF
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

host -t SRV _ldap._tcp.$DOMAIN || rollback

kinit $ADMIN@$REALM || rollback

samba-tool domain join $DOMAIN DC -U"$ADMIN" --realm=$REALM --dns-backend=SAMBA_INTERNAL || rollback

systemctl enable samba-ad-dc
systemctl restart samba-ad-dc

samba-tool drs showrepl || rollback

samba-tool ntacl sysvolcheck || samba-tool ntacl sysvolreset

read -p "Transferir FSMO? (s/n): " FSMO
if [ "$FSMO" == "s" ]; then
  samba-tool fsmo transfer --role=all
fi

echo "✅ Concluído"