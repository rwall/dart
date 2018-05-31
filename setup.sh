#!/bin/bash
# vim: set bg=dark
USER_BASE=/opt/dart
MEDIA_BASE=/media/storage
GIT_BASE=/tmp/dart
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LIDARR_PKG_URL='https://ci.appveyor.com/api/buildjobs/pqte2q546889w0yh/artifacts/Lidarr.develop.0.3.0.430.linux.tar.gz'
LIDARR_SAVEFILE='/tmp/lidarr.tgz'
COUCHPOTATO_GIT_REPO='https://github.com/CouchPotato/CouchPotatoServer.git'

VPN_USER=
VPN_PASS=

IP=AUTO
SUBNET=AUTO
# comment this out if you don't have additional subnets to set
ADTL_SUBNET='10.10.20.0/24'

# Make sure it's run as root
if [[ $UID -ne 0 ]]; then
	echo "This script must be run as root" 1>&2
	echo "try: sudo $0" 1>&2
	exit 1
fi

if [ "$IP" = "AUTO" ]; then
	IP=$(ip r g 8.8.8.8 | head -n 1 | cut -d " " -f 7)
	echo "Auto-detected IP: $IP"
fi
if [ "$SUBNET" = "AUTO" ]; then
	SUBNET=$(ip a s | grep ${IP} | sed -e 's/\s\+/ /g;' | cut -d " " -f 3)
	echo "Auto-detected subnet: $SUBNET"
fi

if [ -z "$IP" ] || [ -z  "$SUBNET" ]; then
	echo "Unable to determine IP or subnet." 1>&2
	exit
fi

echo "Using IP address: ${IP}"
echo "Using subnet: ${SUBNET}"

echo "Setting up VPN credentials"
if [ -z "$VPN_USER" ]; then
	read -p "VPN username: " VPN_USER
fi
if [ -z "$VPN_PASS" ]; then
	read -p "VPN password: " -s VPN_PASS
	echo
fi

echo "Adding repositories"
echo "    Mono"
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF >/dev/null 2>&1
echo "deb https://download.mono-project.com/repo/ubuntu stable-bionic main" > /etc/apt/sources.list.d/mono-official-stable.list 2>/dev/null
echo "    Sonarr" 
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys FDA5DFFC >/dev/null 2>&1
echo "deb http://apt.sonarr.tv/ master main" > /etc/apt/sources.list.d/sonarr.list 2>/dev/null

echo "Updating APT and upgrading packages"
apt-get update 2>&1 >/dev/null && apt-get dist-upgrade -y 2>&1 >/dev/null

echo "Installing required packages..."
apt-get install -y mono-devel vim git openvpn sabnzbdplus python-sabyenc transmission-daemon 2>&1 >/dev/null
echo "    done."

if [ -d $SCRIPT_DIR/.git ] && [ -d $SCRIPT_DIR/files ]; then
	echo "Found local repo, using it: $SCRIPT_DIR"
	GIT_BASE=$SCRIPT_DIR
else
	echo "Fetching files"
	git clone https://github.com/rwall/dart ${GIT_BASE} >/dev/null 2>&1 || (echo "    Repo already checked out. updating..." && cd ${GIT_BASE} && git pull)
fi

echo "Making directories"
mkdir -p ${USER_BASE} 
mkdir -p ${MEDIA_BASE}/incoming/transmission/complete
mkdir -p ${MEDIA_BASE}/incoming/transmission/incomplete


echo "Disabling IPv6 and IP forwarding"
cat << EOF > /etc/sysctl.d/99-dart.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.ip_forward = 0
EOF
sysctl -p

echo "Installing iptables"
$(export FILE=etc/network/if-up.d/iptables; cp ${GIT_BASE}/files/$FILE /$FILE)
cat << EOF > /etc/iptables.save
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -s ${SUBNET} -j ACCEPT
-A INPUT -s ${ADTL_SUBNET} -j ACCEPT
-A INPUT -i tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p udp -m udp --sport 1194 -j ACCEPT
-A INPUT -i tun+ -p icmp -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -d ${SUBNET} -j ACCEPT
-A OUTPUT -d ${ADTL_SUBNET} -j ACCEPT
-A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
COMMIT
EOF

echo "Setting up openvpn VPN"
cat << EOF > /etc/openvpn/ipredator.auth
${VPN_USER}
${VPN_PASS}
EOF
chmod og-rw /etc/openvpn/ipredator.auth

mkdir -p /etc/openvpn/config >/dev/null 2>&1

$(export FILE='etc/openvpn/ipredator.conf'; cp ${GIT_BASE}/files/$FILE /$FILE)
$(export FILE='etc/openvpn/ipredator_dns_up.sh'; cp ${GIT_BASE}/files/$FILE /$FILE)
$(export FILE='etc/openvpn/ipredator_dns_down.sh'; cp ${GIT_BASE}/files/$FILE /$FILE)
$(export FILE='etc/openvpn/config/IPredator.se.ca.crt'; cp ${GIT_BASE}/files/$FILE /$FILE)
$(export FILE='etc/openvpn/config/IPredator.se.ta.key'; cp ${GIT_BASE}/files/$FILE /$FILE)

echo "Setting up software"
echo "    SabNZB"
USERNAME=sabnzb
useradd -r -d ${USER_BASE}/$USERNAME -m -N $USERNAME >/dev/null 2>&1
$(export FILE='etc/systemd/system/sabnzb.service'; cp ${GIT_BASE}/files/$FILE /$FILE) >/dev/null 2>&1
sed -i -e "s/host =.*/host = ${IP}/" ${USER_BASE}/sabnzb/.sabnzbd/sabnzbd.ini
systemctl enable sabnzb.service >/dev/null 2>&1
SAB_API_KEY=$(grep -E '^api_key = ' ${USER_BASE}/sabnzb/.sabnzbd/sabnzbd.ini | cut -d " " -f 3)
echo "api key: $SAB_API_KEY"

echo "    Transmission"
USERNAME=transmission
useradd -r -d ${USER_BASE}/$USERNAME -m -N $USERNAME >/dev/null 2>&1
cp -r /var/lib/transmission-daemon/.config ${USER_BASE}/${USERNAME}/
chown -R ${USERNAME}: ${USER_BASE}/${USERNAME}/.config
ln -s ${USER_BASE}/${USERNAME}/.config/transmission-daemon ${USER_BASE}/${USERNAME}/info >/dev/null 2>&1
chown root:users /etc/transmission-daemon
chown ${USERNAME}:users /etc/transmission-daemon/*
sed -i -e "s#^CONFIG_DIR=.*#CONFIG_DIR=\"${USER_BASE}/${USERNAME}/info\"#" /etc/default/transmission-daemon
sed -i -e "s/^setuid debian-transmission/setuid ${USERNAME}/" /etc/init/transmission-daemon.conf
sed -i -e 's/^setgid debian-transmission/setgid users/' /etc/init/transmission-daemon.conf
sed -i -e 's/"download-dir":.*/"download-dir": "\/media\/storage\/incoming\/transmission\/complete",/' /etc/transmission-daemon/settings.json
sed -i -e 's/"incomplete-dir":.*/"incomplete-dir": "\/media\/storage\/incoming\/transmission\/incomplete",/' /etc/transmission-daemon/settings.json
sed -i -e 's/"incomplete-dir-enabled":.*/"incomplete-dir-enabled": true,/' /etc/transmission-daemon/settings.json
#sed -i -e 's/"rpc-host-whitelist":.*/"rpc-host-whitelist": "127.0.0.1",/' /etc/transmission-daemon/settings.json

echo "    Sonarr"
USERNAME=sonarr
useradd -r -d ${USER_BASE}/$USERNAME -m -N $USERNAME >/dev/null 2>&1
$(export FILE='etc/systemd/system/sonarr.service'; cp ${GIT_BASE}/files/$FILE /$FILE) >/dev/null 2>&1
systemctl enable sonarr.service >/dev/null 2>&1

echo "    Lidarr"
USERNAME=lidarr
useradd -r -d ${USER_BASE}/$USERNAME -m -N $USERNAME >/dev/null 2>&1
if [ ! -e ${LIDARR_SAVEFILE} ]; then
	wget -O "${LIDARR_SAVEFILE}" "${LIDARR_PKG_URL}" >/dev/null 2>&1
fi
tar -xzf ${LIDARR_SAVEFILE} --directory ${USER_BASE}/${USERNAME}/ >/dev/null 2>&1
chown -R lidarr: ${USER_BASE}/${USERNAME}/Lidarr >/dev/null 2>&1
$(export FILE='etc/systemd/system/lidarr.service'; cp ${GIT_BASE}/files/$FILE /$FILE) >/dev/null 2>&1
sed -i -e "s#<BindAddress>.*</BindAddress>#<BindAddress>${IP}</BindAddress>#" ${USER_BASE}/${USERNAME}/.config/Lidarr/config.xml
LIDARR_API_KEY=$(grep -e "ApiKey" ${USER_BASE}/lidarr/.config/Lidarr/config.xml | cut -d ">" -f 2 | cut -d "<" -f 1)
echo "lidarr api key: $LIDARR_API_KEY"
systemctl enable lidarr.service >/dev/null 2>&1

echo "    CouchPotato"
USERNAME=couchpotato
useradd -r -d ${USER_BASE}/$USERNAME -m -N $USERNAME >/dev/null 2>&1
git clone ${COUCHPOTATO_GIT_REPO} ${USER_BASE}/${USERNAME}/CouchPotatoServer >/dev/null 2>&1
$(export FILE='etc/systemd/system/couchpotato.service'; cp ${GIT_BASE}/files/$FILE /$FILE) >/dev/null 2>&1
systemctl enable couchpotato.service >/dev/null 2>&1

systemctl start sabnzb >/dev/null 2>&1
# TODO transmission
systemctl start sonarr >/dev/null 2>&1
systemctl start lidarr >/dev/null 2>&1
systemctl start couchpotato >/dev/null 2>&1
echo "Done."
