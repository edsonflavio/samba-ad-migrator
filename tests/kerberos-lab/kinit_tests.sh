#!/bin/bash
REALM=LAB2003.LOCAL
ADMINPW='Passw0rd!'
ENC="aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 des-cbc-md5 des-cbc-crc"

cat > /tmp/A_hardened.conf <<EOF
[libdefaults]
 default_realm = $REALM
 dns_lookup_kdc = false
 permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
 default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
 default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
[realms]
 $REALM = {
  kdc = 127.0.0.1
 }
EOF

cat > /tmp/B_fixed.conf <<EOF
[libdefaults]
 default_realm = $REALM
 dns_lookup_realm = false
 dns_lookup_kdc = false
 allow_weak_crypto = true
 allow_rc4 = true
 allow_des3 = true
 default_tkt_enctypes = $ENC
 default_tgs_enctypes = $ENC
 permitted_enctypes = $ENC
[realms]
 $REALM = {
  kdc = 127.0.0.1
 }
EOF

run_test () {
  local label="$1" conf="$2"
  echo "##################################################################"
  echo "# TESTE: $label"
  echo "##################################################################"
  kdestroy 2>/dev/null
  echo "$ADMINPW" | KRB5_CONFIG="$conf" kinit Administrator@$REALM 2>&1
  local rc=$?
  echo "--> kinit exit code: $rc"
  if [ $rc -eq 0 ]; then
    KRB5_CONFIG="$conf" klist -e 2>&1 | sed -n '1,8p'
  fi
  echo
}

run_test "A) Postura moderna (somente AES) — esperado FALHAR" /tmp/A_hardened.conf
run_test "B) krb5.conf gerado pelos scripts (correcao) — esperado FUNCIONAR" /tmp/B_fixed.conf
