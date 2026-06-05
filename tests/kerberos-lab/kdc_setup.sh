#!/bin/bash
set -e
REALM=LAB2003.LOCAL
MASTER=masterpass123
ADMINPW='Passw0rd!'

# KDC config: emula um DC Windows 2003 que so possui chaves RC4 (arcfour).
cat > /etc/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
 kdc_ports = 88,750

[realms]
 $REALM = {
  database_name = /var/lib/krb5kdc/principal
  admin_keytab = /etc/krb5kdc/kadm5.keytab
  acl_file = /etc/krb5kdc/kadm5.acl
  key_stash_file = /etc/krb5kdc/stash
  master_key_type = aes256-cts
  supported_enctypes = arcfour-hmac:normal
  max_life = 10h 0m 0s
  max_renewable_life = 7d 0h 0m 0s
 }
EOF

# krb5.conf que o PROCESSO KDC usa. allow_rc4=true => o KDC emite tickets RC4
# (como faz um DC 2003). allow_weak_crypto p/ tolerar enctypes legados.
cat > /etc/krb5.conf <<EOF
[libdefaults]
 default_realm = $REALM
 dns_lookup_realm = false
 dns_lookup_kdc = false
 allow_weak_crypto = true
 allow_rc4 = true

[realms]
 $REALM = {
  kdc = localhost
  admin_server = localhost
 }
EOF

echo '*/admin@LAB2003.LOCAL *' > /etc/krb5kdc/kadm5.acl

# Cria a base e o principal admin (recebem somente chave arcfour-hmac/RC4).
kdb5_util create -s -r $REALM -P $MASTER
kadmin.local -q "addprinc -pw $ADMINPW Administrator" >/dev/null

echo "=== Enctypes das chaves (krbtgt e Administrator) — deve ser SO arcfour ==="
kadmin.local -q "getprinc krbtgt/$REALM@$REALM" | grep -i "Key:"
kadmin.local -q "getprinc Administrator@$REALM" | grep -i "Key:"

# Sobe o KDC em background.
pkill krb5kdc 2>/dev/null || true
sleep 1
/usr/sbin/krb5kdc
sleep 2
echo "=== KDC ouvindo na 88? ==="
ss -lunp 2>/dev/null | grep :88 || (apt-get install -y -qq iproute2 >/dev/null 2>&1; ss -lunp | grep :88) || echo "ss indisponivel"
echo "SETUP_OK"
