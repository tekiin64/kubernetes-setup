#!/bin/bash

# Define node IPs and SSH usernames
declare -A NODES=(
    ["master1_ip"]="user1"
    ["master2_ip"]="user2"
    ["master3_ip"]="user3"
    ["worker1_ip"]="user4"
    ["worker2_ip"]="user5"
    ["worker3_ip"]="user6"
    ["haproxy_server_ip"]="haproxy_user"
)

# Kubernetes, Istio, and ArgoCD versions
KUBERNETES_VERSION="1.23.0"
ISTIO_VERSION="1.13.2"
ARGOCD_VERSION="v2.3.2"

# Function to update and install required packages on each node
update_and_install() {
    sudo apt-get update -y
    sudo apt-get install -y apt-transport-https ca-certificates curl
    sudo curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
    sudo apt-get update -y
    sudo apt-get install -y kubelet=${KUBERNETES_VERSION}-00 kubeadm=${KUBERNETES_VERSION}-00 kubectl=${KUBERNETES_VERSION}-00
    sudo apt-mark hold kubelet kubeadm kubectl
}

# Prepare Kubernetes prerequisites
prepare_kubernetes() {
    sudo modprobe overlay
    sudo modprobe br_netfilter

    sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
    sudo sysctl --system
    sudo apt-get update && sudo apt-get install -y containerd
    sudo mkdir -p /etc/containerd
    sudo containerd config default > /etc/containerd/config.toml
    sudo systemctl restart containerd
    sudo systemctl enable containerd
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
}

# Function to execute SSH commands
execute_ssh() {
    local ip="$1"
    local command="$2"
    ssh "${NODES[$ip]}"@"$ip" "$command"
}

# Initialize the master node and install network plugin
init_master() {
    execute_ssh "$1" "
        sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=\$(hostname -i) --control-plane-endpoint=$1;
        mkdir -p \$HOME/.kube;
        sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config;
        sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config;
        kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml;"
}

# Join worker nodes to the cluster
join_cluster() {
    local join_command="$1"
    local node_ip="$2"
    execute_ssh "$node_ip" "sudo $join_command"
}

# Install Istio with the default profile
install_istio() {
    execute_ssh "master1_ip" "
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -;
        cd istio-${ISTIO_VERSION};
        export PATH=\$PWD/bin:\$PATH;
        istioctl install --set profile=default -y;
        kubectl label namespace default istio-injection=enabled;"
}

# Install and configure HAProxy on a specific server
install_haproxy() {
    execute_ssh "haproxy_server_ip" "
        sudo apt-get install -y haproxy;
        sudo tee /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

frontend kubernetes-frontend
    bind *:8443
    mode tcp
    default_backend kubernetes-backend

backend kubernetes-backend
    mode tcp
    balance roundrobin
    option tcp-check
EOF
        for node_ip in ${!NODES[@]}; do
            if [[ \$node_ip == *"master"* ]]; then
                echo \"    server \${node_ip} \${node_ip}:6443 check\" | sudo tee -a /etc/haproxy/haproxy.cfg
            fi
        done;
        sudo systemctl restart haproxy;"
}

# Install Argo CD
install_argocd() {
    execute_ssh "master1_ip" "
        kubectl create namespace argocd;
        kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml;"
}

# Main function
main() {
    # Update, install, and prepare each node
    for node_ip in "${!NODES[@]}"; do
        execute_ssh "$node_ip" "$(typeset -f update_and_install prepare_kubernetes); update_and_install; prepare_kubernetes"
    done

    # Initialize the first master and get join command
    init_master "master1_ip"
    JOIN_COMMAND=$(execute_ssh "master1_ip" "kubeadm token create --print-join-command")

    # Join other masters and workers to the cluster
    for node_ip in "${!NODES[@]}"; do
        if [[ "$node_ip" != "master1_ip" && "$node_ip" != "haproxy_server_ip" ]]; then
            join_cluster "$JOIN_COMMAND" "$node_ip"
        fi
    done

    # Install Istio, HAProxy, and Argo CD
    install_istio
    install_haproxy
    install_argocd
}

# Run the script
main
