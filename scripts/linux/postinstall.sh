#!/bin/sh
# Runs after `dpkg -i`/`rpm -i` installs the bundle to /opt/mcvpn (fpm
# --after-install, see .github/workflows/release.yml). Adds a launcher menu
# entry and a `mcvpn` command; nothing here needs to survive uninstall
# beyond what the package manager already tracks.
set -e

ln -sf /opt/mcvpn/mcvpn /usr/bin/mcvpn

mkdir -p /usr/share/applications
cat > /usr/share/applications/mcvpn.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=mcvpn
Comment=VPN over a Minecraft session
Exec=/opt/mcvpn/mcvpn
Terminal=false
Categories=Network;
EOF

chmod +x /opt/mcvpn/tun-engine 2>/dev/null || true
