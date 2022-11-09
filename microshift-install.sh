#!/usr/bin/env bash
set -e -o pipefail

# Install dependencies
install_dependencies() {
    sudo apt-get install -y policycoreutils-python-utils conntrack firewalld
}

# Setup firewall
establish_firewall () {
    sudo systemctl enable firewalld --now
    sudo firewall-cmd --zone=public --permanent --add-port=6443/tcp
    sudo firewall-cmd --zone=public --permanent --add-port=30000-32767/tcp
    sudo firewall-cmd --zone=public --permanent --add-port=2379-2380/tcp
    sudo firewall-cmd --zone=public --add-masquerade --permanent
    sudo firewall-cmd --zone=public --add-port=80/tcp --permanent
    sudo firewall-cmd --zone=public --add-port=443/tcp --permanent
    sudo firewall-cmd --zone=public --add-port=10250/tcp --permanent
    sudo firewall-cmd --zone=public --add-port=10251/tcp --permanent
    sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
    sudo firewall-cmd --reload
}

install_crio() {
    echo "deb [signed-by=/usr/share/keyrings/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_Testing/ /" | sudo tee /etc/apt/sources.list.d/crio-archive.list > /dev/null

    sudo mkdir -p /usr/share/keyrings
    curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_Testing/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg

    sudo apt-get update -y
    sudo apt-get install -y cri-o cri-o-runc cri-tools containernetworking-plugins
}


# CRI-O config to match MicroShift networking values
crio_conf() {
    sudo sh -c 'cat << EOF > /etc/cni/net.d/100-crio-bridge.conf
{
    "cniVersion": "0.4.0",
    "name": "crio",
    "type": "bridge",
    "bridge": "cni0",
    "isGateway": true,
    "ipMasq": true,
    "hairpinMode": true,
    "ipam": {
        "type": "host-local",
        "routes": [
            { "dst": "0.0.0.0/0" }
        ],
        "ranges": [
            [{ "subnet": "10.42.0.0/24" }]
        ]
    }
}
EOF'
}

# Start CRI-O
verify_crio() {
    sudo systemctl enable crio
    sudo systemctl restart crio
}

# Download and install kubectl
get_kubectl() {
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/$ARCH/kubectl"
    sudo chmod +x ./kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl
}


# Download and install microshift
get_microshift() {
    curl -LO https://github.com/redhat-et/microshift/releases/download/$VERSION/microshift-linux-$ARCH
    curl -LO https://github.com/redhat-et/microshift/releases/download/$VERSION/release.sha256

    BIN_SHA="$(sha256sum microshift-linux-$ARCH | awk '{print $1}')"
    KNOWN_SHA="$(grep "microshift-linux-$ARCH" release.sha256 | awk '{print $1}')"

    if [[ "$BIN_SHA" != "$KNOWN_SHA" ]]; then
        echo "SHA256 checksum failed" && exit 1
    fi

    sudo chmod +x microshift-linux-$ARCH
    sudo mv microshift-linux-$ARCH /usr/local/bin/microshift

    cat << EOF | sudo tee /usr/lib/systemd/system/microshift.service
[Unit]
Description=MicroShift
After=crio.service

[Service]
WorkingDirectory=/usr/local/bin/
ExecStart=microshift run
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    if [ "$DISTRO" = "ubuntu" ] && [ "$OS_VERSION" = "18.04" ]; then
        sudo sed -i 's|^ExecStart=microshift|ExecStart=/usr/local/bin/microshift|' /usr/lib/systemd/system/microshift.service
    fi
    if [ "$DISTRO" != "ubuntu" ]; then
        sudo restorecon -v /usr/local/bin/microshift
    fi
    sudo systemctl enable microshift.service --now
}

# validation checks for deployment
validation_check(){
    echo $HOSTNAME | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)' && echo "Correct"
    if [ $? != 0 ];
    then
        echo "======================================================================"
        echo "!!! WARNING !!!"
        echo "The hostname $HOSTNAME does not follow FQDN, which might cause problems while operating the cluster."
        echo "See: https://github.com/redhat-et/microshift/issues/176"
        echo
        echo "If you face a problem or want to avoid them, please update your hostname and try again."
        echo "Example: 'sudo hostnamectl set-hostname $HOSTNAME.example.com'"
        echo "======================================================================"
    else
        echo "$HOSTNAME is a valid machine name continuing installation"
    fi
}


# Script execution
#get_distro
get_arch
#get_os_version
pre-check-installation
validation_check
#install_dependencies
#establish_firewall
#install_crio
crio_conf
verify_crio
get_kubectl
get_microshift

until sudo test -f /var/lib/microshift/resources/kubeadmin/kubeconfig
do
    sleep 2
done
prepare_kubeconfig
