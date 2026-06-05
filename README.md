# samba-ad-migrator

Scripts para migração de um domínio **Active Directory** (testado a partir do
**Windows Server 2003**) para um **Samba AD DC** executando em **Debian Trixie**.

A migração é feita ingressando o Samba como **controlador de domínio adicional**
(`samba-tool domain join ... DC`), replicando o diretório via DRS e, depois,
transferindo os papéis **FSMO** para o novo DC. Ao final, o Windows 2003 pode ser
rebaixado/desativado.

Há duas implementações equivalentes — use a que preferir:

| Arquivo | Linguagem | Observação |
|---|---|---|
| `samba_ad_migrator.py` | Python 3 | Mais detalhado: rollback, validações e logging estruturado. |
| `samba_migracao_ad.sh` | Bash | Versão enxuta com os mesmos passos. |

---

## É necessário usar root?

**Sim, para a migração real.** Os scripts instalam pacotes (`apt`), escrevem em
`/etc` (`/etc/hosts`, `/etc/krb5.conf`), alteram o hostname (`hostnamectl`) e
gerenciam serviços (`systemctl`). Sem privilégios de root essas operações falham.

- Execute com `sudo` (ou como root).
- Se você rodar como usuário comum **sem** `--dry-run`, o script aborta com uma
  mensagem clara.

**O modo `--dry-run` NÃO precisa de root** — ele apenas simula e imprime o que
seria feito, sem tocar no sistema. Nesse modo, se `/var/log` não for gravável, o
log cai automaticamente para um arquivo local (`./samba-ad-migration.log`).

---

## Pré-requisitos

- Debian Trixie com acesso à internet (para `apt`).
- Conectividade de rede com o(s) DC(s) do Windows Server 2003 de origem.
- **DNS** do servidor Debian apontando para o DNS do AD 2003 (necessário para
  resolver os registros `SRV` `_ldap._tcp.<domínio>`).
- **Relógio sincronizado por NTP** com a mesma fonte de tempo do AD. O Kerberos
  rejeita autenticações com diferença de relógio maior que ~5 minutos.
- Credenciais de um usuário **administrador do domínio** de origem.
- O **realm** Kerberos em MAIÚSCULAS (ex.: `EXEMPLO.LOCAL`).

### Validações automáticas de pré-requisitos

Antes de alterar qualquer coisa, ambos os scripts executam checagens
**somente-leitura** e exibem avisos (não destrutivos):

- **Root**: garante execução privilegiada no modo real (dispensado em `--dry-run`).
- **NTP/relógio**: verifica `timedatectl ... NTPSynchronized` e alerta se o relógio
  não estiver sincronizado.
- **DNS do domínio**: confirma que os registros `SRV` `_ldap._tcp.<domínio>` são
  resolvíveis (alcançabilidade do AD de origem).
- **DNS direto/reverso**: confirma que `<hostname>.<domínio>` resolve para o IP
  informado e que o reverso do IP aponta de volta para o FQDN.
- **Realm**: alerta se não estiver em MAIÚSCULAS.

---

## Passo a passo

### 1. Prepare o ambiente

- Ajuste o DNS do Debian para o DNS do AD 2003.
- Sincronize o relógio (ex.: `chrony`/`systemd-timesyncd`) com a fonte do AD.
- Tenha em mãos: domínio, realm (MAIÚSCULO), usuário admin, hostname e IP do novo DC.

### 2. Simule com `--dry-run` (sem root)

Revise os comandos e o conteúdo que seria gravado (incl. `/etc/krb5.conf`) sem
alterar nada:

```bash
python3 samba_ad_migrator.py --dry-run
# ou
bash samba_migracao_ad.sh --dry-run
```

### 3. Execute a migração real (como root)

```bash
sudo python3 samba_ad_migrator.py
# ou
sudo bash samba_migracao_ad.sh
```

O script irá, em ordem:

1. Validar pré-requisitos.
2. Instalar `samba`, `krb5-user`, `winbind`, `smbclient`, `dnsutils` (e `chrony` na versão Python).
3. Definir hostname e `/etc/hosts`.
4. Gerar `/etc/krb5.conf` com os enctypes compatíveis (ver seção Kerberos abaixo).
5. Validar DNS (`SRV`) e Kerberos (`kinit`).
6. Ingressar como DC adicional (`samba-tool domain join ... DC`).
7. Habilitar/iniciar o serviço `samba-ad-dc`.
8. Verificar replicação (`samba-tool drs showrepl`) e SYSVOL (`ntacl sysvolcheck`).
9. Opcionalmente transferir os papéis **FSMO** (`samba-tool fsmo transfer --role=all`).

### 4. Pós-migração

- Aponte o DNS dos clientes para o novo DC Samba.
- Teste autenticação e acesso a recursos.
- Após confirmar a estabilidade, **rebaixe/desative** o Windows Server 2003.
- Eleve o nível funcional do domínio e **remigre as senhas para AES** quando o 2003
  sair, removendo então os enctypes fracos (RC4/DES) do `/etc/krb5.conf` por segurança.

---

## Sobre o Kerberos (enctypes) — por que isso importa

O AD do **Windows Server 2003** só oferece enctypes Kerberos legados:
`arcfour-hmac-md5` (RC4, o padrão do 2003), `des-cbc-md5` e `des-cbc-crc`. Ele
**não suporta AES** (introduzido a partir do Windows Server 2008).

O **krb5 do Debian Trixie (1.21)** desabilita criptografia fraca por padrão
(`allow_weak_crypto = false`) e prioriza AES. Sem ajuste, o `kinit` e o
`samba-tool domain join` falham com:

```
KDC has no support for encryption type
```

Por isso, os scripts geram um `/etc/krb5.conf` que habilita explicitamente os
enctypes legados (mantendo AES no topo para o novo DC e clientes modernos):

```ini
[libdefaults]
 default_realm = EXEMPLO.LOCAL
 dns_lookup_realm = false
 dns_lookup_kdc = true
 allow_weak_crypto = true
 allow_rc4 = true
 allow_des3 = true
 default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 des-cbc-md5 des-cbc-crc
 default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 des-cbc-md5 des-cbc-crc
 permitted_enctypes  = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 des-cbc-md5 des-cbc-crc
```

`allow_rc4` e `allow_des3` são chaves do krb5 1.21 (ignoradas silenciosamente em
versões anteriores).

> **Segurança:** RC4/DES são fracos. Eles são necessários apenas durante a
> coexistência com o Windows 2003. Após a desativação do 2003, remova-os e use
> apenas AES.

---

## Logs

- Padrão: `/var/log/samba-ad-migration.log`.
- Sem permissão de root (ex.: em `--dry-run`), cai para `./samba-ad-migration.log`.

---

## Solução de problemas

| Sintoma | Causa provável | Ação |
|---|---|---|
| `KDC has no support for encryption type` | enctypes incompatíveis | Confirme o `/etc/krb5.conf` gerado (seção Kerberos). |
| `kinit` falha com erro de relógio (skew) | relógio fora de sincronia | Sincronize o NTP com a fonte do AD. |
| `_ldap._tcp.<domínio>` não resolve | DNS não aponta para o AD | Ajuste o DNS do Debian para o DNS do AD 2003. |
| Join falha na replicação | conectividade/credenciais | Verifique rede, firewall e o usuário admin informado. |

---

## Aviso

Faça a migração em ambiente controlado e tenha **backup** do AD de origem antes
de transferir os papéis FSMO. Teste sempre primeiro com `--dry-run`.
