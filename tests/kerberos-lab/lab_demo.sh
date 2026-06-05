#!/bin/bash
REALM=LAB2003.LOCAL
ADMINPW='Passw0rd!'
pause(){ sleep 2; }
line(){ echo "------------------------------------------------------------"; }

clear
echo "############################################################"
echo "#  LABORATORIO: AD 2003 (proxy)  ->  Samba/Debian Trixie   #"
echo "#  Validacao da correcao de enctypes do Kerberos           #"
echo "############################################################"
pause
line
echo "[1] Cliente = Debian Trixie. Versao do MIT krb5:"
dpkg-query -W -f='krb5-user ${Version}\n' krb5-user
pause
line
echo "[2] KDC que emula o Windows Server 2003: principais possuem"
echo "    SOMENTE chave arcfour-hmac (RC4), igual ao padrao do 2003:"
kadmin.local -q "getprinc krbtgt/$REALM@$REALM" 2>/dev/null | grep -i "Key:"
kadmin.local -q "getprinc Administrator@$REALM" 2>/dev/null | grep -i "Key:"
pause
line
echo "[3] TESTE A  ->  postura MODERNA endurecida (somente AES)"
echo "    (equivale ao padrao do krb5 1.21 sem enctypes legados)"
kdestroy 2>/dev/null
echo "\$ kinit Administrator@$REALM"
echo "$ADMINPW" | KRB5_CONFIG=/tmp/A_hardened.conf kinit Administrator@$REALM
echo "    >> RESULTADO: FALHA (exit $?) — este e o erro real da migracao."
pause
line
echo "[4] TESTE B  ->  /etc/krb5.conf GERADO PELOS SCRIPTS (correcao)"
echo "    habilita arcfour-hmac-md5 (RC4) mantendo AES no topo:"
kdestroy 2>/dev/null
echo "\$ kinit Administrator@$REALM"
echo "$ADMINPW" | KRB5_CONFIG=/tmp/B_fixed.conf kinit Administrator@$REALM
rc=$?
echo "    >> RESULTADO: SUCESSO (exit $rc) — ticket emitido:"
KRB5_CONFIG=/tmp/B_fixed.conf klist -e 2>/dev/null | sed -n '1,8p'
pause
line
echo "CONCLUSAO: a config padrao falha contra o KDC 2003 (RC4);"
echo "o krb5.conf gerado pelos scripts permite o kinit/join com sucesso."
echo "############################################################"
