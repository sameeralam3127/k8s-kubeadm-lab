# Windows guide

Everything the toolkit does on a Mac, it does on Windows. This page covers the
Windows-specific setup and the exact command translations.

There are two distinct roles a Windows machine can play. Decide which you want:

| Role | What runs on Windows | Read |
|---|---|---|
| **Worker host** | A VirtualBox VM that joins a cluster driven from a Mac | Part A |
| **Lab controller** | The repo and the `lab.ps1` CLI, driving both VMs | Part B |

Both at once is fine and common: the Windows box runs the worker VM *and* drives
the lab.

---

## Part A — Windows as a VM host

### 1. Prepare the host

Open PowerShell **as Administrator**:

```powershell
cd <repo>\windows
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\Setup-WindowsHost.ps1
```

This installs the OpenSSH client, VirtualBox, kubectl and Windows Terminal, and
warns you if Hyper-V is enabled (Hyper-V and VirtualBox fight over the CPU's
virtualisation extensions — you can only use one).

> **Using Hyper-V instead?** That is fine, and often faster on Windows Pro.
> Create an "External" virtual switch bound to your physical NIC — that is
> Hyper-V's equivalent of bridged networking — and build the VM through
> Hyper-V Manager. Everything from `lab.ps1 check` onwards is identical.

### 2. Create the VM

Download the Ubuntu Server ISO from <https://ubuntu.com/download/server>, then:

```powershell
.\New-LabVM.ps1 -Name k8s-worker1 -IsoPath C:\iso\ubuntu-24.04.1-live-server-amd64.iso -Start
```

The script creates the VM with a **bridged** adapter, a unique MAC, 2 vCPU and
2 GB RAM, then prints exactly which installer options to choose. The ones that
matter:

- Network: accept DHCP, then **write down the IPv4 address**. It must be on your
  normal LAN subnet. `10.0.2.x` means NAT, not bridged — the nodes will never
  see each other.
- Server name: `k8s-worker1`
- **Tick "Install OpenSSH server"** — the whole toolkit drives the node over SSH
- Snaps: select none

### 3. Eject the ISO after installing

```powershell
VBoxManage storageattach k8s-worker1 --storagectl IDE --port 0 --device 0 --type dvddrive --medium none
```

### 4. Confirm it is reachable

From whichever machine holds the repo:

```powershell
ping 192.168.1.102
ssh ubuntu@192.168.1.102
```

If SSH works, you are done with Part A — build the cluster from the Mac with
`./lab up`, or continue to Part B to drive it from Windows.

---

## Part B — Windows as the lab controller

### 1. Get the repo and configure it

```powershell
git clone <this-repo> k8s-kubeadm-lab
cd k8s-kubeadm-lab
Copy-Item lab.env.example lab.env
notepad lab.env
```

Set `CP_IP`, `WORKERS` and `SSH_USER` to match your VMs.

> `SSH_KEY` accepts a POSIX-style path like `$HOME/.ssh/k8s-lab`; `lab.ps1`
> translates it to `C:\Users\you\.ssh\k8s-lab` automatically.

### 2. Set up SSH keys

```powershell
.\windows\lab.ps1 ssh-setup       # asks for each node's password once
.\windows\lab.ps1 check
```

### 3. Build and use the cluster

```powershell
.\windows\lab.ps1 up
.\windows\lab.ps1 status
.\windows\lab.ps1 kubectl get pods -A
```

### 4. Use kubectl natively from Windows

```powershell
.\windows\lab.ps1 kubeconfig
$env:KUBECONFIG = "$PWD\kubeconfig"
kubectl get nodes
```

To make it permanent for your user:

```powershell
[Environment]::SetEnvironmentVariable('KUBECONFIG', "$PWD\kubeconfig", 'User')
```

---

## Command translation

| macOS / Linux | Windows PowerShell |
|---|---|
| `./lab check` | `.\windows\lab.ps1 check` |
| `./lab up` | `.\windows\lab.ps1 up` |
| `./lab status` | `.\windows\lab.ps1 status` |
| `./lab backup nightly` | `.\windows\lab.ps1 backup nightly` |
| `./lab restore --latest` | `.\windows\lab.ps1 restore --latest` |
| `./lab dr-drill` | `.\windows\lab.ps1 dr-drill` |
| `./lab ssh cp` | `.\windows\lab.ps1 ssh cp` |
| `./lab run all 'uptime'` | `.\windows\lab.ps1 run all uptime` |
| `export KUBECONFIG=./kubeconfig` | `$env:KUBECONFIG = "$PWD\kubeconfig"` |
| `cat labs/01-workloads/README.md` | `Get-Content .\labs\01-workloads\README.md` |
| `chmod +x script.sh` | not needed |

The lab exercises themselves are pure `kubectl` and work identically. The
`verify.sh` scripts are bash — run them through the control plane:

```powershell
.\windows\lab.ps1 run cp 'bash -s' < .\labs\01-workloads\verify.sh
```

Or run them under WSL, or Git Bash, with `KUBECONFIG` pointed at the fetched
kubeconfig.

---

## Windows-specific problems

**"cannot be loaded because running scripts is disabled"**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**`ssh` is not recognised**

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Or install Git for Windows, which bundles `ssh` and `scp`.

**VirtualBox VMs are extremely slow, or refuse to start**

Hyper-V is enabled and has claimed the virtualisation extensions. Either move to
Hyper-V for the VM, or:

```powershell
bcdedit /set hypervisorlaunchtype off
# reboot
```

Note this also disables WSL2, Docker Desktop and Windows Sandbox.

**The VM gets a `10.0.2.x` address**

The adapter is NAT, not bridged. Shut the VM down, then:

```powershell
VBoxManage list bridgedifs                                    # find your NIC name
VBoxManage modifyvm k8s-worker1 --nic1 bridged --bridgeadapter1 "<NIC name>"
```

Wi-Fi adapters sometimes refuse to bridge properly. A wired connection is far
more reliable for this lab.

**`scp` fails with "protocol error" or path problems**

Windows paths with backslashes confuse `scp` when they land on the remote side.
The toolkit handles this, but if you call `scp` by hand, quote the remote path:

```powershell
scp "ubuntu@192.168.1.101:/opt/etcd-backups/snap.db" .
```

**Line endings break the node scripts**

If Git checked the repo out with CRLF endings, bash on the VM fails with
`bad interpreter: /usr/bin/env bash^M`. The repo ships a `.gitattributes` that
forces LF for shell scripts. If you hit it anyway:

```powershell
git config core.autocrlf input
git rm --cached -r .
git reset --hard
```

**Windows Firewall blocks the VM**

Bridged VMs are on your LAN, so this is rare — but if the Windows host also runs
something the cluster needs to reach, allow it:

```powershell
New-NetFirewallRule -DisplayName "k8s lab" -Direction Inbound -Protocol TCP -LocalPort 6443,30000-32767 -Action Allow
```
