#!/usr/bin/env bash
set -e -o pipefail

# Install dependencies
install_dependencies() {
    sudo apt-get install -y policycoreutils-python-utils conntrack firewalld wget curl
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

    sudo mkdir -p /usr/share/keyrings && sudo rm /usr/share/keyrings/libcontainers-archive-keyring.gpg
    curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_Testing/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg

    sudo apt-get update -y
    sudo apt-get install -y cri-o-runc cri-tools containernetworking-plugins

    #wget https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.25:/1.25.1/Debian_11/arm64/cri-o_1.25.1~0_arm64.deb

    sudo dpkg -i cri-o_1.25.1~0_arm64.deb
}


# CRI-O config to match MicroShift networking values
crio_conf() {
    sudo rm /etc/cni/net.d/*
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
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/arm64/kubectl"
    sudo chmod +x ./kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl
}


# Download and install microshift
get_microshift() {
    curl -LO https://github.com/redhat-et/microshift/releases/download/nightly/microshift-linux-arm64

    sudo chmod +x microshift-linux-arm64
    sudo mv microshift-linux-arm64 /usr/local/bin/microshift

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

# Locate kubeadmin configuration to default kubeconfig location
prepare_kubeconfig() {
    mkdir -p $HOME/.kube
    if [ -f $HOME/.kube/config ]; then
        mv $HOME/.kube/config $HOME/.kube/config.orig
    fi
    sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig:$HOME/.kube/config.orig  /usr/local/bin/kubectl config view --flatten > $HOME/.kube/config
}

# Script execution
echo
echo
echo "???? Installing dependencies..."
install_dependencies

echo
echo
echo "???? Configuring firewall..."
establish_firewall

echo
echo
echo "???????  Installing crio..."
install_crio

echo
echo
echo "??????  Configuring crio for microshift..."
crio_conf

echo
echo
echo "???? Verifying crio start..."
verify_crio

echo
echo
echo "??? Installing kubectl..."
get_kubectl

echo
echo
echo "???????  Installing microshift..."
get_microshift

until sudo test -f /var/lib/microshift/resources/kubeadmin/kubeconfig
do
    sleep 2
done

echo
echo
echo "???? Preparing kubeconfig..."
prepare_kubeconfig
