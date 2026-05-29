#!/usr/bin/env python3

import os
import subprocess
import sys
import logging
from datetime import datetime

LOG_FILE = "/var/log/samba-ad-migration.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def log(msg):
    print(msg)
    logging.info(msg)

def error(msg):
    print(f"❌ {msg}")
    logging.error(msg)

def run(cmd, critical=True):
    log(f">> {cmd}")
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        error(f"Erro ao executar: {cmd}")
        if critical:
            rollback()
            sys.exit(1)
    return result.returncode

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
    print("==============================================")
    print(" MIGRAÇÃO ENTERPRISE — SAMBA AD")
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

    with open("/etc/hosts", "w") as f:
        f.write(f"127.0.0.1 localhost\n{ip} {hostname}.{domain} {hostname}\n")

    # -------------------------
    # KERBEROS
    # -------------------------
    with open("/etc/krb5.conf", "w") as f:
        f.write(f"""[libdefaults]
 default_realm = {realm}
 dns_lookup_realm = false
 dns_lookup_kdc = true
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
    print(f"📄 Log completo: {LOG_FILE}")
    print("\nPróximos passos:")
    print("- Ajustar DNS dos clientes")
    print("- Testar autenticação")
    print("- Despromover Windows 2003")

if __name__ == "__main__":
    main()