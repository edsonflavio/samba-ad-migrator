#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys
import logging
from datetime import datetime

LOG_FILE = "/var/log/samba-ad-migration.log"

# Quando True, nenhum comando e executado e nenhum arquivo do sistema e alterado.
DRY_RUN = False

# Caminho efetivo do log (pode cair para um arquivo local quando /var/log nao e gravavel).
ACTIVE_LOG = LOG_FILE


def _setup_logging():
    global ACTIVE_LOG
    # /var/log exige root; cai para um arquivo local para permitir --dry-run sem root.
    for path in (LOG_FILE, os.path.join(os.getcwd(), "samba-ad-migration.log")):
        try:
            logging.basicConfig(
                filename=path,
                level=logging.INFO,
                format="%(asctime)s [%(levelname)s] %(message)s",
            )
            ACTIVE_LOG = path
            return
        except OSError:
            continue
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    ACTIVE_LOG = "(stderr)"


_setup_logging()

def log(msg):
    print(msg)
    logging.info(msg)

def error(msg):
    print(f"❌ {msg}")
    logging.error(msg)

def run(cmd, critical=True):
    log(f">> {cmd}")
    if DRY_RUN:
        log("   [DRY-RUN] comando nao executado")
        return 0
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        error(f"Erro ao executar: {cmd}")
        if critical:
            rollback()
            sys.exit(1)
    return result.returncode


def write_file(path, content):
    log(f">> escrevendo {path}")
    if DRY_RUN:
        log(f"   [DRY-RUN] conteudo que seria gravado em {path}:")
        for line in content.splitlines():
            log(f"   | {line}")
        return
    with open(path, "w") as f:
        f.write(content)

# -------------------------
# ROLLBACK
# -------------------------
def rollback():
    log("⚠️ Iniciando rollback seguro...")

    run("systemctl stop samba-ad-dc", False)
    run("rm -rf /var/lib/samba/*", False)
    run("rm -rf /etc/samba/smb.conf", False)

    log("Rollback concluído (parcial). Ambiente limpo.")

# -------------------------
# VALIDAÇÕES
# -------------------------
def check_dns(domain):
    log("🔎 Validando DNS SRV...")
    return run(f"host -t SRV _ldap._tcp.{domain}", critical=True)

def check_kerberos(admin, realm):
    log("🔐 Testando Kerberos...")
    return run(f"kinit {admin}@{realm}", critical=True)

def check_sysvol():
    log("📁 Verificando SYSVOL...")
    rc = run("samba-tool ntacl sysvolcheck", critical=False)
    if rc != 0:
        log("Corrigindo SYSVOL...")
        run("samba-tool ntacl sysvolreset", True)

def check_replication():
    log("🔁 Verificando replicação AD...")
    return run("samba-tool drs showrepl", True)

# -------------------------
# MAIN
# -------------------------
def main():
    global DRY_RUN
    parser = argparse.ArgumentParser(
        description="Migracao de AD (Windows) para Samba AD DC."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simula a migracao: nenhum comando e executado e nenhum arquivo e alterado.",
    )
    args = parser.parse_args()
    DRY_RUN = args.dry_run

    print("==============================================")
    print(" MIGRAÇÃO ENTERPRISE — SAMBA AD")
    if DRY_RUN:
        print(" *** MODO DRY-RUN (simulacao, sem alteracoes) ***")
    print("==============================================")

    domain = input("Domínio: ")
    realm = input("Realm (MAIÚSCULO): ")
    admin = input("Usuário admin: ")
    hostname = input("Hostname: ")
    ip = input("IP: ")

    log("==== INício da migração ====")

    input("\n⚠️ Confirme que DNS e NTP estão corretos. Enter para continuar...")

    # -------------------------
    # INSTALAÇÃO
    # -------------------------
    run("apt update")
    run("apt install -y samba krb5-user winbind smbclient dnsutils chrony")

    # -------------------------
    # HOSTNAME
    # -------------------------
    run(f"hostnamectl set-hostname {hostname}.{domain}")

    write_file(
        "/etc/hosts",
        f"127.0.0.1 localhost\n{ip} {hostname}.{domain} {hostname}\n",
    )

    # -------------------------
    # KERBEROS
    # -------------------------
    # O AD do Windows Server 2003 só oferece enctypes legados (RC4/DES).
    # O krb5 do Debian Trixie desabilita crypto fraca por padrão, então
    # habilitamos esses enctypes (mantendo AES para o novo DC Samba e clientes
    # modernos) para que o kinit e o "domain join" consigam negociar com o 2003.
    legacy_enctypes = (
        "aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 "
        "arcfour-hmac-md5 des-cbc-md5 des-cbc-crc"
    )
    write_file("/etc/krb5.conf", f"""[libdefaults]
 default_realm = {realm}
 dns_lookup_realm = false
 dns_lookup_kdc = true
 allow_weak_crypto = true
 allow_rc4 = true
 allow_des3 = true
 default_tkt_enctypes = {legacy_enctypes}
 default_tgs_enctypes = {legacy_enctypes}
 permitted_enctypes = {legacy_enctypes}
""")

    check_dns(domain)
    check_kerberos(admin, realm)

    # -------------------------
    # JOIN
    # -------------------------
    confirm = input("Entrar como DC adicional? (s/n): ")
    if confirm.lower() != "s":
        sys.exit(0)

    run(f"samba-tool domain join {domain} DC -U\"{admin}\" --realm={realm} --dns-backend=SAMBA_INTERNAL")

    # -------------------------
    # SERVIÇOS
    # -------------------------
    run("systemctl stop smbd nmbd winbind || true", False)
    run("systemctl disable smbd nmbd winbind || true", False)

    run("systemctl enable samba-ad-dc")
    run("systemctl restart samba-ad-dc")

    # -------------------------
    # VALIDAÇÕES
    # -------------------------
    check_replication()
    check_sysvol()

    # -------------------------
    # FSMO
    # -------------------------
    fsm = input("Transferir FSMO agora? (s/n): ")
    if fsm.lower() == "s":
        run("samba-tool fsmo transfer --role=all")
        run("samba-tool fsmo show")

    # -------------------------
    # RELATÓRIO
    # -------------------------
    log("✅ MIGRAÇÃO FINALIZADA COM SUCESSO")

    print("\n✅ MIGRAÇÃO CONCLUÍDA")
    print(f"📄 Log completo: {ACTIVE_LOG}")
    print("\nPróximos passos:")
    print("- Ajustar DNS dos clientes")
    print("- Testar autenticação")
    print("- Despromover Windows 2003")

if __name__ == "__main__":
    main()