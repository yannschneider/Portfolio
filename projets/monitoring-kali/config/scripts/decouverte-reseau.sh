#!/usr/bin/env bash
# Decouverte des appareils du reseau local (nmap -sn) :
#  - cibles de ping pour Prometheus (/etc/prometheus/targets/lan-hotes.yml)
#  - inventaire CSV cumulatif (/var/lib/monitoring/inventaire.csv)
#  - metriques reseau_hotes_actifs / reseau_hotes_inventories pour Grafana
set -euo pipefail
. /etc/monitoring/monitoring.env
install -d /var/lib/monitoring
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
nmap -sn -n -e "$MON_IF" --host-timeout 5s -oX "$TMP" "$LAN_CIDR" >/dev/null

python3 - "$TMP" "$GATEWAY" <<'PY'
import csv, os, sys, time, xml.etree.ElementTree as ET
xml_f, gateway = sys.argv[1:3]
inv_f = "/var/lib/monitoring/inventaire.csv"
tgt_f = "/etc/prometheus/targets/lan-hotes.yml"
prom_f = "/var/lib/node_exporter/textfile_collector/decouverte.prom"
now = time.strftime("%Y-%m-%d %H:%M")

actifs = []
for h in ET.parse(xml_f).getroot().iter("host"):
    if h.find("status").get("state") != "up":
        continue
    d = {"ip": "", "mac": "", "constructeur": ""}
    for a in h.iter("address"):
        if a.get("addrtype") == "ipv4": d["ip"] = a.get("addr")
        if a.get("addrtype") == "mac":
            d["mac"] = a.get("addr").lower()
            d["constructeur"] = (a.get("vendor") or "").replace("'", " ")
    actifs.append(d)

champs = ["ip", "mac", "constructeur", "premiere_vue", "derniere_vue"]
inv = {}
if os.path.exists(inv_f):
    for r in csv.DictReader(open(inv_f), delimiter=";"):
        inv[r["mac"] or r["ip"]] = r
for d in actifs:
    cle = d["mac"] or d["ip"]
    r = inv.setdefault(cle, {**d, "premiere_vue": now})
    r.update(ip=d["ip"], derniere_vue=now)
    if d["constructeur"]: r["constructeur"] = d["constructeur"]
with open(inv_f + ".tmp", "w", newline="") as f:
    w = csv.DictWriter(f, champs, delimiter=";"); w.writeheader()
    for r in sorted(inv.values(), key=lambda r: tuple(int(x) for x in r["ip"].split("."))):
        w.writerow({k: r.get(k, "") for k in champs})
os.replace(inv_f + ".tmp", inv_f)

# Minimisation des donnees (RGPD) : Prometheus/Grafana ne recoivent que le prefixe
# constructeur de l'adresse MAC ; l'adresse complete reste dans l'inventaire local.
def masque(mac):
    return ":".join(mac.split(":")[:3] + ["xx"] * 3) if mac else "inconnue"
lignes = []
for d in actifs:
    if d["ip"] == gateway: continue        # deja dans infra.yml
    lignes.append(f"- targets: ['{d['ip']}']")
    lignes.append(f"  labels: {{role: 'lan', mac: '{masque(d['mac'])}', constructeur: '{d['constructeur'] or 'inconnu'}'}}")
open(tgt_f + ".tmp", "w").write("\n".join(lignes) + "\n" if lignes else "[]\n")
os.replace(tgt_f + ".tmp", tgt_f)

open(prom_f + ".tmp", "w").write(
    "# HELP reseau_hotes_actifs Appareils repondant au dernier balayage\n# TYPE reseau_hotes_actifs gauge\n"
    f"reseau_hotes_actifs {len(actifs)}\n"
    "# HELP reseau_hotes_inventories Appareils differents vus depuis la mise en service\n# TYPE reseau_hotes_inventories gauge\n"
    f"reseau_hotes_inventories {len(inv)}\n"
    "# HELP reseau_dernier_balayage_timestamp Date du dernier balayage\n# TYPE reseau_dernier_balayage_timestamp gauge\n"
    f"reseau_dernier_balayage_timestamp {int(time.time())}\n")
os.replace(prom_f + ".tmp", prom_f)
print(f"{len(actifs)} appareil(s) actif(s), {len(inv)} inventorie(s)")
PY
chown prometheus:prometheus /etc/prometheus/targets/lan-hotes.yml 2>/dev/null || true
