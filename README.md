# OpenWrt Tor-Only Firewall

[![Shell](https://img.shields.io/badge/lang-shell-blue)]()
[![OpenWrt](https://img.shields.io/badge/platform-OpenWrt-informational)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Ce projet configure un pare-feu **“Tor-only”** sur OpenWrt :  
tout le trafic **LAN → WAN** est **bloqué**, **sauf** les connexions **TCP vers les relais Tor** (IPv4/IPv6), grâce à `nftables` / `fw4` et des `ipset`.  
La liste des relais est **mise à jour automatiquement** via l’API **Onionoo** (Tor Project) au **boot** et **chaque jour à 04:00**.

---

## 🚀 Installation (une commande)

Sur votre routeur OpenWrt (en root) :
```sh
opkg update && opkg install curl
sh -c "curl -fsSL https://raw.githubusercontent.com/Derbosoft/openwrt-tor-only-firewall/refs/heads/main/scripts/setup-tor-only-firewall.sh | sh"
