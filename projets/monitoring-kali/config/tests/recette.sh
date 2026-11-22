#!/usr/bin/env bash
# Cahier de recette de la sonde kali-monitor (a lancer en root dans la VM)
# Sortie : /var/lib/monitoring/recette.csv  (id;test;attendu;obtenu;resultat)
. /etc/monitoring/monitoring.env
export LC_ALL=C.UTF-8
OUT=/var/lib/monitoring/recette.csv
echo "id;test;attendu;obtenu;resultat" > "$OUT"
q() { curl -s 'http://localhost:9090/api/v1/query' --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "vide"'; }
r() { local ok=KO; [ "$5" = 0 ] && ok=OK; echo "$1;$2;$3;$4;$ok" >> "$OUT"; echo "[$ok] $1 $2 -> $4"; }

# T01 Systeme
H=$(hostname); U=$(id -nG yann | tr ' ' '\n' | grep -cx sudo)
[ "$H" = kali-monitor ] && [ "$U" = 1 ]; r T01 "Nom de la sonde et compte administrateur" "kali-monitor, yann membre de sudo" "$H, sudo=$U" $?

# T03 Services
N=0; L=""
for s in suricata darkstat "arpwatch@$MON_IF" vnstat prometheus prometheus-node-exporter prometheus-blackbox-exporter grafana-server nftables ssh; do
  systemctl is-active --quiet "$s" && N=$((N+1)) || L="$L $s"
done
[ "$N" = 10 ]; r T03 "Services de supervision actifs" "10/10" "$N/10${L:+ (arret :$L)}" $?

# T04 Decouverte
A=$(q reseau_hotes_actifs)
[ "${A%.*}" -ge 2 ] 2>/dev/null; r T04 "Decouverte des appareils du LAN (nmap)" ">= 2 appareils" "$A appareils" $?

# T05 Cibles Prometheus
T=$(curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[]] | length')
D=$(curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.health!="up")] | length')
[ "$D" = 0 ]; r T05 "Collecte Prometheus" "toutes les cibles up" "$((T-D))/$T up" $?

# T06 Ping passerelle
P=$(q "probe_success{job=\"ping\",role=\"passerelle\"}"); RTT=$(q "probe_icmp_duration_seconds{phase=\"rtt\",role=\"passerelle\"}")
RTT_MS=$(awk -v s="$RTT" 'BEGIN {printf "%.1f", s*1000}')
[ "$P" = 1 ]; r T06 "Ping de la box ($GATEWAY)" "joignable" "succes=$P, rtt=$RTT_MS ms" $?

# T07 DNS
P=$(q 'probe_success{job="dns"}'); [ "$P" = 1 ]; r T07 "Resolution DNS par la box" "www.kali.org resolu" "succes=$P" $?
# T08 Web
P=$(q 'min(probe_success{job="web"})'); [ "$P" = 1 ]; r T08 "Acces Web Internet (HTTP 2xx)" "2 sites joignables" "succes=$P" $?

# T09 Grafana
G=$(curl -s -u "yann:$WEB_PASSWORD" 'http://localhost:3000/api/search?query=' | jq -r '[.[].title] | join(" + ")')
echo "$G" | grep -q "Supervision du r"; r T09 "Connexion Grafana (yann) et tableaux de bord" "tableau Supervision present" "$G" $?
# T18 Grafana sans authentification
C=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/search)
[ "$C" = 401 ]; r T18 "Grafana refuse l'acces anonyme" "HTTP 401" "HTTP $C" $?

# T11 Detection d'un balayage de ports (SYN) et T12 balayage ICMP
B0=$(q 'sum(suricata_alertes_total{categorie="scan"})')
nmap -sS -Pn -n -T4 -p 1-300 -e "$MON_IF" 192.168.1.13 >/dev/null 2>&1
nmap -sn -PE --send-ip -n -e "$MON_IF" "$(echo "$LAN_CIDR" | sed 's#0/24#1-40#')" >/dev/null 2>&1
sleep 15
S1=$(grep -c 'LOCAL SCAN balayage de ports TCP SYN' /var/log/suricata/fast.log)
S2=$(grep -c 'LOCAL SCAN balayage ICMP' /var/log/suricata/fast.log)
[ "$S1" -ge 1 ]; r T11 "Suricata detecte un scan de ports (nmap -sS)" "alerte SID 9000001" "$S1 alerte(s)" $?
[ "$S2" -ge 1 ]; r T12 "Suricata detecte un balayage ICMP" "alerte SID 9000002" "$S2 alerte(s)" $?

# T15 Panne simulee d'un service de supervision
systemctl stop darkstat
/usr/local/bin/metriques-securite
echo "Attente des alertes (150 s)..."
sleep 150
FIRING=$(curl -s localhost:9090/api/v1/alerts | jq -r '[.data.alerts[] | select(.state=="firing") | .labels.alertname] | unique | join(",")')
echo "$FIRING" | grep -q ScanDetecte; r T13 "Alerte Prometheus apres le scan" "ScanDetecte en cours" "${FIRING:-aucune}" $?
echo "$FIRING" | grep -q ServiceSupervisionArrete; r T14 "Alerte si un service s'arrete (darkstat coupe)" "ServiceSupervisionArrete" "${FIRING:-aucune}" $?
systemctl start darkstat; sleep 3
systemctl is-active --quiet darkstat; r T15 "Remise en service de darkstat" "service actif" "$(systemctl is-active darkstat)" $?

# T16 Sauvegarde et restauration
F=$(/usr/local/bin/sauvegarde-config | awk '{print $4}')
TMP=$(mktemp -d); tar -xzf "$F" -C "$TMP" etc/prometheus/prometheus.yml 2>/dev/null
cmp -s "$TMP/etc/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml; r T16 "Sauvegarde puis restauration d'un fichier" "fichier restaure identique" "$(basename "$F")" $?
rm -rf "$TMP"

# T19 arpwatch
AW=$(journalctl -u "arpwatch@$MON_IF" --no-pager -o cat | grep -c 'new station')
[ "$AW" -ge 1 ]; r T19 "arpwatch enregistre les appareils" ">= 1 'new station'" "$AW" $?
# T20 vnStat
V=$(vnstat -i "$MON_IF" --oneline 2>/dev/null | cut -d';' -f4)
[ -n "$V" ]; r T20 "vnStat compte le trafic de $MON_IF" "volume du jour" "${V:-aucun}" $?

echo; column -t -s ';' "$OUT"
