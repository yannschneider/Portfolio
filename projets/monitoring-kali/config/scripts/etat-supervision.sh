#!/usr/bin/env bash
# Resume de l'etat de la supervision en une commande
. /etc/monitoring/monitoring.env
V='\e[32m'; R='\e[31m'; J='\e[33m'; N='\e[0m'
echo -e "\n  Supervision kali-monitor - $(date '+%d/%m/%Y %H:%M')"
echo    "  Reseau surveille : $LAN_CIDR sur $MON_IF (passerelle $GATEWAY)"
echo -e "\n  Services"
for s in suricata darkstat "arpwatch@$MON_IF" vnstat prometheus prometheus-node-exporter \
         prometheus-blackbox-exporter grafana-server nftables ssh; do
  if systemctl is-active --quiet "$s"; then echo -e "   ${V}[OK]${N}     $s"; else echo -e "   ${R}[ARRET]${N}  $s"; fi
done
echo -e "\n  Equipements"
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=probe_success{job="ping"}' \
 | jq -r '.data.result[] | "\(.metric.instance)\t\(.metric.role)\t\(.value[1])"' 2>/dev/null \
 | sort -t. -k4n | while IFS=$'\t' read -r ip role ok; do
     if [ "$ok" = "1" ]; then echo -e "   ${V}[UP]${N}     $ip ($role)"; else echo -e "   ${R}[DOWN]${N}   $ip ($role)"; fi
   done
echo -e "\n  Alertes Prometheus en cours"
A=$(curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.state=="firing") | "   [\(.labels.severite)] \(.annotations.resume)"' 2>/dev/null)
if [ -n "$A" ]; then echo -e "${J}$A${N}"; else echo -e "   ${V}aucune${N}"; fi
echo -e "\n  Dernieres alertes Suricata"
if [ -s /var/log/suricata/fast.log ]; then tail -n 5 /var/log/suricata/fast.log | cut -c1-150 | sed 's/^/   /'; else echo "   aucune"; fi
echo -e "\n  Interfaces Web (depuis le PC hote)"
echo "   Grafana    http://127.0.0.1:3000"
echo "   darkstat   http://127.0.0.1:3001"
echo -e "   Prometheus http://127.0.0.1:9090\n"
