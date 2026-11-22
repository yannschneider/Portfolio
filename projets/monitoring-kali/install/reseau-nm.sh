#!/bin/sh
# Connexions NetworkManager de la sonde :
#   eth0 = administration + acces Internet (NAT VirtualBox, route par defaut)
#   eth1 = reseau local surveille (pont sur la carte Wi-Fi), sans route par defaut
set -e
OLD=$(nmcli -t -f NAME,DEVICE con show | awk -F: '$2=="eth1" {print $1; exit}')
if [ -n "$OLD" ] && [ "$OLD" != lan-surveillee ]; then
  nmcli con mod "$OLD" connection.id lan-surveillee connection.interface-name eth1
fi
nmcli -t -f NAME con show | grep -qx admin-nat || \
  nmcli con add type ethernet ifname eth0 con-name admin-nat ipv4.method auto ipv6.method ignore connection.autoconnect yes
nmcli con mod admin-nat ipv4.never-default no ipv4.route-metric 50
nmcli con mod lan-surveillee ipv4.never-default yes ipv4.route-metric 200 ipv6.method ignore
nmcli con up admin-nat
nmcli con up lan-surveillee
sleep 3
ip -br -4 a
ip r
