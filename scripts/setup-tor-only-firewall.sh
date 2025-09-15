#!/bin/sh
set -e

echo "[*] OpenWrt Tor-only firewall – installation"

# ---- 0) Prérequis & contexte
[ "$(id -u)" -eq 0 ] || { echo "ERR: exécuter en root"; exit 1; }

WAN_IFS="wan|wan6|wwan"     # adapte si ton WAN s'appelle autrement
CRONLINE='0 4 * * * /usr/bin/update_tor_relays.sh >/var/log/tor_relays_update.log 2>&1'
API_URL="https://onionoo.torproject.org/details?running=true&fields=or_addresses"

# ---- 1) Paquets
echo "[*] Installation des paquets requis"
opkg update
opkg install curl jq nftables kmod-nft-core ca-bundle >/dev/null

# ---- 2) Nettoyage ancien état (règles/sets/ipsets)
echo "[*] Nettoyage ancienne config liée à Tor (si présente)"
# Supprimer règles portant ces noms
for n in Allow-LAN-to-TorRelays-v4 Allow-LAN-to-TorRelays-v6 Drop-LAN-to-WAN-except-Tor; do
  idx=$(uci show firewall 2>/dev/null | awk -F'[][]' "/config rule/{i++} /name='$n'/{print i-1}")
  [ -n "$idx" ] && uci delete firewall.@rule[$idx] || true
done
# Supprimer ipsets tor_relays_v4/v6
for s in tor_relays_v4 tor_relays_v6; do
  idx=$(uci show firewall 2>/dev/null | awk -F'[][]' "/config ipset/{i++} /name='$s'/{print i-1}")
  [ -n "$idx" ] && uci delete firewall.@ipset[$idx] || true
done
uci commit firewall || true
/etc/init.d/firewall restart >/dev/null || true

# ---- 3) Créer les ipsets fw4 (nftables)
echo "[*] Déclaration des ipsets (v4/v6)"
uci add firewall ipset >/dev/null
uci set firewall.@ipset[-1].name='tor_relays_v4'
uci set firewall.@ipset[-1].family='ipv4'
uci set firewall.@ipset[-1].match='dst_ip'
uci set firewall.@ipset[-1].enabled='1'

uci add firewall ipset >/dev/null
uci set firewall.@ipset[-1].name='tor_relays_v6'
uci set firewall.@ipset[-1].family='ipv6'
uci set firewall.@ipset[-1].match='dst_ip'
uci set firewall.@ipset[-1].enabled='1'

uci commit firewall
/etc/init.d/firewall restart

# ---- 4) Créer les règles fw4
echo "[*] Création des règles fw4 (ACCEPT vers ipsets, puis DROP)"
# Autoriser LAN -> Tor (IPv4)
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-LAN-to-TorRelays-v4'
uci set firewall.@rule[-1].family='ipv4'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].ipset='tor_relays_v4'
uci set firewall.@rule[-1].target='ACCEPT'

# Autoriser LAN -> Tor (IPv6)
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-LAN-to-TorRelays-v6'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].ipset='tor_relays_v6'
uci set firewall.@rule[-1].target='ACCEPT'

# Tout le reste LAN -> WAN = DROP
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Drop-LAN-to-WAN-except-Tor'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].target='DROP'

uci commit firewall
/etc/init.d/firewall restart

# ---- 5) Script de mise à jour des relais Tor
echo "[*] Installation du script /usr/bin/update_tor_relays.sh"
cat >/usr/bin/update_tor_relays.sh <<'EOS'
#!/bin/sh
set -e
API_URL="https://onionoo.torproject.org/details?running=true&fields=or_addresses"
TMP="/tmp/tor_relays.$$"
mkdir -p "$TMP"

# Télécharger toutes les OR addresses actives
curl -s "$API_URL" \
| jq -r '.relays[]?.or_addresses[]?' \
| sed -E 's/^\[([0-9a-fA-F:]+)\]:[0-9]+$/\1/; s/^([0-9\.]+):[0-9]+$/\1/' \
| sort -u > "$TMP/all.txt"

# Split IPv4/IPv6
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$TMP/all.txt" > "$TMP/v4.txt" || true
grep -E ':' "$TMP/all.txt" > "$TMP/v6.txt" || true

count_v4=$(wc -l < "$TMP/v4.txt")
count_v6=$(wc -l < "$TMP/v6.txt")

# Seuils de sécurité (éviter de vider les sets si API HS)
if [ "$count_v4" -lt 100 ] && [ "$count_v6" -lt 50 ]; then
  echo "[WARN] Onionoo pauvre: v4=$count_v4 v6=$count_v6. MAJ annulée."
  rm -rf "$TMP"
  exit 0
fi

# Flush puis ajout des IP une par une
nft flush set inet fw4 tor_relays_v4 2>/dev/null || true
nft flush set inet fw4 tor_relays_v6 2>/dev/null || true

if [ -s "$TMP/v4.txt" ]; then
  while read ip; do [ -n "$ip" ] && nft add element inet fw4 tor_relays_v4 { $ip } || true; done < "$TMP/v4.txt"
fi
if [ -s "$TMP/v6.txt" ]; then
  while read ip; do [ -n "$ip" ] && nft add element inet fw4 tor_relays_v6 { $ip } || true; done < "$TMP/v6.txt"
fi

rm -rf "$TMP"
EOS
chmod +x /usr/bin/update_tor_relays.sh

# ---- 6) Hotplug: mise à jour au boot (ifup du WAN)
echo "[*] Hotplug au boot (wan up)"
cat >/etc/hotplug.d/iface/95-tor-relays-update <<EOF2
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
  $WAN_IFS)
    ( sleep 10; /usr/bin/update_tor_relays.sh ) &
  ;;
esac
EOF2
chmod +x /etc/hotplug.d/iface/95-tor-relays-update

# ---- 7) Cron: tous les jours à 04:00
echo "[*] Planification quotidienne (04:00)"
touch /etc/crontabs/root
# retirer anciennes lignes similaires
sed -i '\#/usr/bin/update_tor_relays.sh#d' /etc/crontabs/root
echo "$CRONLINE" >> /etc/crontabs/root
/etc/init.d/cron restart

# ---- 8) Première mise à jour + vérifs
echo "[*] Première synchronisation de la liste Tor"
if /usr/bin/update_tor_relays.sh; then
  echo "[*] OK – sets remplis. Exemples :"
  nft list set inet fw4 tor_relays_v4 | head -n 12 || true
  nft list set inet fw4 tor_relays_v6 | head -n 12 || true
else
  echo "[WARN] Échec MAJ initiale – réessaie au prochain cron/hotplug."
fi

echo "[✓] Installation terminée.
- Sans Tor côté client : Internet bloqué (LAN->WAN).
- Avec Tor Browser : OK.
- Mise à jour au boot (ifup WAN) + chaque jour à 04:00.
"
