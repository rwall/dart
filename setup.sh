#!/bin/bash
# vim: set bg=dark
USER_BASE=/opt/dart
MEDIA_BASE=/media/storage
GIT_BASE=/tmp/dart
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

VPN_USER=a
VPN_PASS=p

IP=AUTO
SUBNET=AUTO
# comment this out if you don't have additional subnets to set
ADTL_SUBNET='10.10.20.0/24'

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



echo "Done."
