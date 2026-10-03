# Cluster installation guide

This guide builds the KubeProvingGround cluster step by step. It targets Kubernetes 1.34.

The lab is written so the cluster steps do not depend on the cloud underneath. Today the only provider
is Azure, and everything specific to it is in [Provider: Azure](#provider-azure) at the end. Stages 1
and 2 describe what any provider has to deliver. Stages 3 to 12 are the same on every provider.

## How the lab works

Every session starts from nothing and ends with `terraform destroy`. Nothing is kept overnight.

Each step is done by hand first. Once I understand it and can break it and fix it, I turn it into an
Ansible role. So some stages below show both: the commands I typed, and the role that now does the same
work. Three steps stay manual on purpose: `kubeadm init`, the CNI and joining nodes.

The daily loop:

1. `terraform apply` builds the machines and copies the Ansible files to the jumphost.
2. Ansible prepares the nodes.
3. I run `kubeadm init`, install the CNI and join the workers by hand.
4. Ansible installs the add-ons.
5. I do the drills.
6. `terraform destroy`.

Because the lab is destroyed every day, a few things that would be mistakes in production are fine
here. SSH is open to the world on the jumphost. Ansible accepts new host keys. The VMs are Spot with the
`Delete` eviction policy, so an eviction is a free rebuild exercise. The master count is 1.

## What gets built

| Stage | What it does |
| --- | --- |
| 1 | Network, VMs, firewall rules, jumphost, API load balancer |
| 2 | Ansible inventory and files copied to the jumphost |
| 3 | Swap off, kernel modules, sysctl |
| 4 | containerd with the systemd cgroup driver |
| 5 | kubeadm, kubelet and kubectl at 1.34 |
| 6 | `kubeadm init` with a fixed API endpoint |
| 7 | kubeconfig for the admin user |
| 8 | CNI that enforces NetworkPolicy |
| 9 | Workers join |
| 10 | Add-ons |
| 11 | Extra control planes |

Two choices cannot be changed later without a rebuild: the control-plane endpoint in stage 6 and the
CNI in stage 8. Read both sections before you run anything.

### What you need

- Terraform 1.12.2 or newer, and `jq`.
- An SSH key at `~/.ssh/id_ed25519.pub`.
- Credentials for the provider. For Azure, see [Provider: Azure](#provider-azure).

Masters and workers have no public IP. You reach them through the jumphost.

## 1. Infrastructure

Whatever the provider, stage 1 has to deliver this:

- A private network with a subnet per role: jumphost, masters, workers.
- Masters and workers with private IPs only. The jumphost has a public IP and is the only way in.
- A firewall rule set per node, so one node can be cut off on its own.
- One stable address for the Kubernetes API on port 6443, in front of the masters, with a private DNS
  name that every node resolves. In this repo the name is `k8s-api.proving-ground.internal`.
- Outbound internet access for masters and workers.
- A Terraform output called `ansible_inventory`, with the groups `k8s-master`, `k8s-worker` and
  `k8s-jumphost`.

Build it from the provider folder under `Infrastructure/terraform/`:

```
terraform init
terraform apply
```

Check it:

```
terraform output -json ansible_inventory | jq
```

You should see the three groups, each host with a private IP under `ansible_host`.

## 2. Ansible inventory and the jumphost

The jumphost is the Ansible control node. Cloud-init installs Ansible and Git on it and creates an
automation SSH key. Every master and worker trusts the public half of that key.

At the end of `terraform apply`, Terraform renders the inventory from its own outputs and copies two
things to the jumphost: the `Infrastructure/ansible/` folder, and the inventory as
`ansible/inventory/cluster.json`. I never type an IP address. The inventory has no ProxyJump because
Ansible already runs inside the private network.

Log in to the jumphost and check:

```
cd ~/ansible
ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph
ansible all -m ping
```

`ansible-inventory --graph` should show `k8s-master`, `k8s-worker` and `k8s-jumphost`. Every master and
worker should answer `SUCCESS` to the ping.

If the groups are missing, see Troubleshooting in the README.

## 3. Node prerequisites

Every node needs swap off, the `overlay` and `br_netfilter` modules loaded, and IPv4 forwarding on.
Without these, `kubeadm init` fails its preflight checks.

By hand, on every master and worker:

```
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

The `common` role does the same thing. Check either way:

```
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
swapon --show
lsmod | grep -E 'overlay|br_netfilter'
```

Both sysctls should print `= 1`. `swapon --show` should print nothing. Both modules should be listed.

`swapoff -a` does not survive a reboot. The `sed` on `/etc/fstab` does. If you skip it, a node that
comes back after a restart has swap on, goes `NotReady`, and the kubelet log mentions swap.

Reference: [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)

## 4. containerd and the systemd cgroup driver

kubeadm sets the kubelet's cgroup driver to `systemd`. containerd has to match, so
`SystemdCgroup` must be `true`.

By hand:

```
sudo apt-get update && sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
```

Then set `SystemdCgroup = true`. The place to set it depends on the containerd version, so run
`containerd --version` first.

containerd 1.x:

```
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

containerd 2.x:

```
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
```

```
sudo systemctl restart containerd
```

The `containerd` role generates the default config and flips `SystemdCgroup` from `false` to `true`
wherever it finds it, so it works on both versions.

Check:

```
containerd config dump | grep -i SystemdCgroup
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock version
```

The first should print `SystemdCgroup = true`. The second should print a `RuntimeName: containerd`
block.

Two things go wrong here:

1. A containerd from a distro package can ship with `cri` listed in `disabled_plugins`. The kubelet then
   cannot talk to it. Regenerating the file with `containerd config default` is the documented fix.
2. If you edit the wrong TOML path for your version, `SystemdCgroup` stays `false` and nothing errors.
   The cluster comes up and gets unstable under memory pressure. Always check with
   `containerd config dump`, not by reading the file you edited.

Reference: [Container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)

## 5. kubeadm, kubelet and kubectl at 1.34

I build one minor version behind the newest so the cluster can be upgraded later. You cannot practise an
upgrade on a cluster that is already at the latest version.

By hand, on every node:

```
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

The `k8s` role does this with `k8s_version: "1.34"` from `roles/k8s/defaults/main.yml`. It installs Helm
on the masters too.

Run stages 3 to 5 with one playbook, from `~/ansible` on the jumphost:

```
ansible-playbook playbooks/k8s_nodes-init.yml
```

Check:

```
kubeadm version -o short
kubectl version --client -o yaml
apt-mark showhold
```

All three should report `v1.34.x`, and all three packages should appear in `showhold`.

The minor version shows up twice in the repository URL, once in the `Release.key` path and once in the
`sources.list` line. When you upgrade, change both. If you change only one, `apt-get update` fails a
signature check that looks like a network problem.

Reference: [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)

## 6. kubeadm init

Run this on `k8s-master-1` only, and read this paragraph first. The kubeadm documentation says that
turning a single control-plane cluster, created without `--control-plane-endpoint`, into a highly
available one is not supported. If I init without the endpoint, adding control planes later means a
rebuild. So the endpoint is always set.

Stage 1 already provides it. `k8s-api.proving-ground.internal` is a private DNS record that points at
the API load balancer, and every node resolves it. Check on `k8s-master-1` before you init:

```
getent hosts k8s-api.proving-ground.internal
```

The address must match `terraform output k8s_api_lb_ip`.

```
sudo kubeadm init \
  --control-plane-endpoint=k8s-api.proving-ground.internal:6443 \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs
```

kubeadm uses its own version, which is the 1.34 patch release the `k8s` role installed.

Check:

```
sudo crictl ps | grep -E 'kube-apiserver|etcd|kube-scheduler|kube-controller-manager'
```

You should see four control-plane containers. After stage 7, `kubectl get nodes` shows the master as
`NotReady`. That is correct, because CoreDNS does not start until the CNI is installed in stage 8.

Three things to know:

1. The pod CIDR must not overlap the node network. The lab's node network is `192.168.0.0/16`, which is
   also Calico's default pod CIDR. So I use `10.244.0.0/16` and give the same value to the CNI in
   stage 8. An overlap does not fail at once. Pods get addresses that collide with node addresses and
   the problems come and go.
2. `--service-cidr` defaults to `10.96.0.0/12`. That does not overlap with either range, so I leave it.
3. `--upload-certs` stores the control-plane certificates in a Secret that expires after two hours. If
   you add control planes later than that, upload them again with
   `sudo kubeadm init phase upload-certs --upload-certs`.

References: [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/),
[kubeadm init](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)

## 7. kubeconfig

On the master, as the admin user:

```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Check that `kubectl get nodes` answers and `kubectl auth can-i '*' '*'` returns `yes`.

`kubeadm init` also writes `/etc/kubernetes/super-admin.conf`. Its certificate belongs to
`system:masters`, which skips RBAC completely. Copy `admin.conf`, never that one. With `super-admin.conf`,
every RBAC drill passes whether or not your role is correct.

## 8. CNI

`kubeadm init` gives me a control plane and no pod network. The kubelet cannot give a pod an IP address
by itself. When it creates a pod sandbox, it reads the first config file in `/etc/cni/net.d/` and runs
the plugin binary that file names from `/opt/cni/bin/`. The plugin does three jobs:

1. It takes an address from the pod CIDR.
2. It creates the veth pair into the pod's network namespace and sets the routes inside the pod.
3. It makes that address reachable from every other node, either by encapsulating the traffic (VXLAN or
   IPIP) or by programming routes into the underlay.

Enforcing NetworkPolicy is a fourth job, and a plugin may skip it. The API server stores a
NetworkPolicy whether or not anything enforces it. There is no error and no warning. On a plugin that
ignores policy, every policy drill passes for the wrong reason. That is why I pick the CNI with care.

With no CNI installed, `/etc/cni/net.d` is empty. The kubelet reports
`NetworkPluginNotReady: cni plugin not initialized`, the node stays `NotReady` and CoreDNS stays
`Pending`. That is the usual signature of a cluster with no pod network.

### Which CNI

Flannel does not implement NetworkPolicy at all, so it is out. That leaves Cilium and Calico. I use
Cilium, for these reasons:

- It installs with Helm.
- The pod CIDR is a `--set` flag. With Calico it is a `sed` over a manifest of several thousand lines.
- Hubble shows which policy dropped which flow. With Calico a blocked connection is just a timeout.
- `cilium connectivity test` proves that enforcement works.

Calico is still a fair choice. It has fewer parts and its iptables dataplane is closer to a default
kubeadm cluster.

On the master, as the admin user. The `k8s` role already installed Helm there.

```
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.244.0.0/16}' \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

Quote the braces in `clusterPoolIPv4PodCIDRList`. They are Helm list syntax, and the shell eats them
otherwise. `routingMode=tunnel` makes pod traffic travel inside VXLAN, so the cloud network does not
need to know the pod CIDR. A provider that can route the pod CIDR natively could use another mode.
Azure cannot without hand-written routes, so the lab keeps the tunnel.

Check that it is installed:

```
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl get nodes
ls /etc/cni/net.d/
```

The Cilium and CoreDNS pods should be `Running`. The master should turn `Ready`. `/etc/cni/net.d/`
should now hold a config file.

Then check that it enforces policy:

```
kubectl create ns np-test
kubectl -n np-test run probe --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n np-test create -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
kubectl -n np-test exec probe -- nslookup kubernetes.default
```

The `nslookup` must fail. If it works, the CNI is not enforcing policy and the policy drills mean
nothing. Clean up with `kubectl delete ns np-test`.

Things that go wrong:

1. A cluster has one pod network, and changing it means a rebuild.
2. If a firewall rule blocks the tunnel, pods on different nodes cannot talk. VXLAN is 8472/UDP. IPIP is
   IP protocol 4, which is neither TCP nor UDP, and hand-written rule sets often drop it.
3. If the CNI's pod CIDR differs from `--pod-network-cidr` in stage 6, pods still start and still get
   addresses. The failures show up later as cross-node problems that come and go.

References: [Network plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/),
[Network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
[Cilium with Helm](https://docs.cilium.io/en/stable/installation/k8s-install-helm/)

## 9. Join the workers

On the master, create a fresh join command:

```
kubeadm token create --print-join-command
```

Run the printed command on each worker with `sudo`.

Check:

```
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
```

All nodes should be `Ready` at `v1.34.x`, and every node should have a CNI pod and a kube-proxy pod.

Bootstrap tokens expire after 24 hours. A join command from yesterday fails with an error that reads
like a certificate problem. Making a new token fixes it.

## 10. The add-ons

When every node is `Ready`, run this on the jumphost:

```
ansible-playbook playbooks/k8s_platform-up.yml
```

It runs against the first master. It installs local-path-provisioner as the default StorageClass,
metrics-server, the Gateway API CRDs with NGINX Gateway Fabric, the NGINX Ingress Controller and
cert-manager. It also installs `etcdctl` and `etcdutl` on that master, at the version of the running etcd.
Safe to run again. Each part has a tag: `storage`, `metrics`, `gateway`, `ingress`, `cert-manager` and
`etcd-tools`. The versions are pinned in `roles/k8s_platform/defaults/main.yml`.

## 11. Extra control planes

This needs `master_count = 3` in Terraform and a certificate key from the last two hours.

On the first master, upload the certificates and create a join command:

```
sudo kubeadm init phase upload-certs --upload-certs
kubeadm token create --print-join-command
```

On each new master, run the printed command with two extra options:

```
--control-plane --certificate-key <key from upload-certs>
```

Check:

```
kubectl get nodes -l node-role.kubernetes.io/control-plane
kubectl -n kube-system get pods -l component=etcd
```

You should see three control-plane nodes, all `Ready`, and three etcd pods.

If you leave out `--control-plane`, the node joins as a plain worker and reports success. You find out
later, when `kubeadm upgrade apply` has nowhere to run.

The new masters have to be in the API load balancer's backend pool. If one master goes down, the
probe on 6443 takes it out of rotation and the other two keep serving the endpoint. Stopping
`kube-apiserver` on one master and watching `kubectl` keep working is a good drill.

Reference: [Highly available clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)

## 12. Check the whole cluster

Run this at the end of every build:

```
kubectl get nodes -o wide
kubectl -n kube-system get pods
kubectl get --raw='/readyz?verbose' | tail -20
kubectl run dns-probe --image=busybox:1.36 --restart=Never --rm -it -- nslookup kubernetes.default
```

All nodes should be `Ready` at the same version. No pod in `kube-system` should be restarting. Every
`readyz` check should say `ok`. The `nslookup` should resolve `kubernetes.default` to a `10.96.x.x`
address.

Reference: [Troubleshooting clusters](https://kubernetes.io/docs/tasks/debug/debug-cluster/)

## 13. End of a session

```
terraform destroy
```

Nothing survives. Before you destroy, copy off anything a later session needs. An etcd snapshot is the
usual one. A drill that restores a snapshot should take its own first, because yesterday's is gone.

## Not done yet

- Three control planes behind the existing load balancer.
- A cluster upgrade playbook from 1.34 to 1.35.
- CSI beyond local-path-provisioner. There is no other storage driver installed.
- Kustomize install paths.
- A teardown playbook (`kubeadm reset` and `rm -rf /etc/cni/net.d`) for rebuilding without a destroy.
- A second provider.

## Provider: Azure

Everything in this section is specific to Azure, the only provider so far. The Terraform is in
`Infrastructure/terraform/azure`.

What you need:

- The Azure CLI, logged in with `az login`.
- Your subscription ID in `TF_VAR_subscription_id`.

The admin user on every VM is `azureadm`. To reach the jumphost:

```
ssh azureadm@$(terraform output -json jumphost_public_ip | jq -r '."1"')
```

What stage 1 builds on Azure: one VNet (`192.168.0.0/16`) with a subnet per role, one NSG per NIC, a
jumphost with a public IP, the masters and two workers. A public Standard load balancer serves the API
on port 6443. The same load balancer gives the masters and workers their outbound internet access. The
README, under Network scope, explains why the load balancer is public.

Defaults: region `centralindia`, Ubuntu 24.04 LTS, `Standard_D2s_v3` Spot, `StandardSSD_LRS` 30 GB.

Things that look wrong and are not:

- `master_security_rules` and `worker_security_rules` are empty by default. Azure's default
  `AllowVnetInBound` rule already allows traffic between nodes, so the cluster ports work, and so does
  the CNI tunnel in stage 8. Some break/fix scenarios depend on that, so do not open ports to fix it.
  The one rule Terraform adds itself is 6443 on the masters, from the load balancer's public IP and the
  jumphost's public IP. Traffic through a public frontend never arrives from a VNet address.
- `ping` and `tracepath` to the internet fail on masters and workers. Load balancer outbound rules
  translate TCP and UDP only. Test with `curl -sI https://google.com` or `nc -vz 1.1.1.1 443`.
- The CNI has to tunnel because the VNet route table knows nothing about `10.244.0.0/16`. Native routing
  would drop cross-node pod traffic unless you write the Azure routes by hand.

## Sources

| Page | Used for |
| --- | --- |
| kubernetes.io, Installing kubeadm | apt repository, keyring, sysctl, modules, swap, ports |
| kubernetes.io, Container runtimes | containerd systemd cgroup setting for 1.x and 2.x, `disabled_plugins`, config reset |
| kubernetes.io, Creating a cluster with kubeadm | `--control-plane-endpoint`, pod network overlap warning, kubeconfig copy, `super-admin.conf`, CoreDNS start order |
| kubernetes.io, kubeadm init | flag meanings, `--upload-certs` expiry, the `upload-certs` phase |
| kubernetes.io, Highly available clusters with kubeadm | adding control-plane nodes |
| kubernetes.io, Network plugins | CNI requirements |
