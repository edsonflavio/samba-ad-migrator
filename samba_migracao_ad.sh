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

cat > /etc/krb5.conf <<EOF
[libdefaults]
 default_realm = $REALM
 dns_lookup_kdc = true
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