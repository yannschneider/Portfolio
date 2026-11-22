#!/usr/bin/env bash
# Transforme les evenements de securite en metriques Prometheus :
#  - alertes Suricata (eve.json) par priorite et par categorie
#  - nouvelles machines detectees par arpwatch
# Les compteurs sont conserves dans /var/lib/monitoring/compteurs.json
set -euo pipefail
. /etc/monitoring/monitoring.env
EVE=/var/log/suricata/eve.json
ETAT=/var/lib/monitoring/compteurs.json
install -d /var/lib/monitoring
[ -f "$ETAT" ] || echo '{"inode":0,"offset":0,"alertes":{},"arp_vus":0,"arp_total":0}' > "$ETAT"

python3 - "$EVE" "$ETAT" "$MON_IF" <<'PY'
import json, os, sys, subprocess
eve, etat_f, iface = sys.argv[1:4]
etat = json.load(open(etat_f))
al = etat.setdefault("alertes", {})

def categorie(a):
    c = (a.get("category") or "").lower()
    s = (a.get("signature") or "").upper()
    if "SCAN" in s or "recon" in c or "reconnaissance" in c: return "scan"
    if "policy" in c or "POLITIQUE" in s: return "politique"
    if "trojan" in c or "malware" in c or "MALWARE" in s: return "malware"
    return "autre"

if os.path.exists(eve):
    st = os.stat(eve)
    if st.st_ino != etat["inode"] or st.st_size < etat["offset"]:
        etat["inode"], etat["offset"] = st.st_ino, 0      # fichier tourne
    with open(eve, "rb") as f:
        f.seek(etat["offset"])
        for line in f:
            try: ev = json.loads(line)
            except ValueError: continue
            if ev.get("event_type") != "alert": continue
            a = ev["alert"]
            k = f'{a.get("severity", 3)}|{categorie(a)}'
            al[k] = al.get(k, 0) + 1
        etat["offset"] = f.tell()

# arpwatch : nombre de "new station" dans le journal depuis le demarrage
try:
    out = subprocess.run(["journalctl", "-b", "-u", f"arpwatch@{iface}", "--no-pager", "-o", "cat"],
                         capture_output=True, text=True, timeout=30).stdout
    vus = out.count("new station")
except Exception:
    vus = etat["arp_vus"]
if vus < etat["arp_vus"]:           # redemarrage : le journal repart de zero
    etat["arp_vus"] = 0
etat["arp_total"] += vus - etat["arp_vus"]
etat["arp_vus"] = vus
json.dump(etat, open(etat_f, "w"))

lignes = ["# HELP suricata_alertes_total Alertes Suricata depuis la mise en service",
          "# TYPE suricata_alertes_total counter"]
for sev in ("1", "2", "3"):
    for cat in ("scan", "politique", "malware", "autre"):
        lignes.append(f'suricata_alertes_total{{severite="{sev}",categorie="{cat}"}} {al.get(f"{sev}|{cat}", 0)}')
lignes += ["# HELP reseau_nouvelles_machines_total Nouvelles machines vues par arpwatch",
           "# TYPE reseau_nouvelles_machines_total counter",
           f"reseau_nouvelles_machines_total {etat['arp_total']}"]
d = "/var/lib/node_exporter/textfile_collector/"
open(d + "securite.prom.tmp", "w").write("\n".join(lignes) + "\n")
os.replace(d + "securite.prom.tmp", d + "securite.prom")
PY
