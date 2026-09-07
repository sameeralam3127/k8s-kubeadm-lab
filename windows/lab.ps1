<#
.SYNOPSIS
    lab.ps1 - control CLI for k8s-kubeadm-lab on a Windows host.

.DESCRIPTION
    The PowerShell twin of the ./lab bash script. It reads the same lab.env,
    pushes the same node scripts over SSH, and runs the same commands - so a
    Windows user and a Mac user drive an identical cluster.

    Requires the Windows OpenSSH client (built into Windows 10 1809+ and
    Windows 11). Run .\Setup-WindowsHost.ps1 first if anything is missing.

.PARAMETER Command
    check | ssh-setup | preflight | prep | init | addons | join | up | verify |
    status | kubeconfig | kubectl | backup | backups | restore | dr-drill |
    diagnostics | reset | ssh | run | labs | help

.EXAMPLE
    .\lab.ps1 check
.EXAMPLE
    .\lab.ps1 up
.EXAMPLE
    .\lab.ps1 kubectl get pods -A
.EXAMPLE
    .\lab.ps1 backup before-upgrade
#>

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The repo root is the parent of this windows\ folder.
$Script:RepoRoot  = Split-Path -Parent $PSScriptRoot
$Script:RemoteDir = '/tmp/k8s-lab'
$Script:Cfg       = $null

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
function Write-Head ($m) {
    Write-Host ''
    Write-Host $m -ForegroundColor White
    Write-Host ('-' * $m.Length) -ForegroundColor DarkGray
}
function Write-Step ($m) { Write-Host "==> " -ForegroundColor Blue -NoNewline; Write-Host $m }
function Write-Ok   ($m) { Write-Host " [ok] " -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn2($m) { Write-Host " [warn] " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Bad  ($m) { Write-Host " [fail] " -ForegroundColor Red -NoNewline; Write-Host $m }
function Write-Info2($m) { Write-Host "        $m" -ForegroundColor DarkGray }
function Write-Skip ($m) { Write-Host " [skip] " -ForegroundColor DarkGray -NoNewline; Write-Host $m }
function Die ($m) { Write-Bad $m; exit 1 }

function Confirm-Action ($prompt) {
    if ($env:ASSUME_YES -eq '1') { return $true }
    $a = Read-Host "$prompt [y/N]"
    return $a -match '^(y|yes)$'
}

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
function Import-LabEnv {
    if ($Script:Cfg) { return $Script:Cfg }

    $envFile = Join-Path $Script:RepoRoot 'lab.env'
    if (-not (Test-Path $envFile)) {
        Write-Bad 'No lab.env found.'
        Write-Info2 'Create one and fill in your IPs:'
        Write-Info2 "    Copy-Item '$(Join-Path $Script:RepoRoot 'lab.env.example')' '$envFile'"
        Write-Info2 "    notepad '$envFile'"
        exit 1
    }

    # Parse the shell-style KEY="value" file. We only need simple assignments.
    $c = @{}
    foreach ($line in Get-Content $envFile) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^\s*(?<k>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<v>.*)$') {
            $k = $Matches['k']
            $v = $Matches['v'].Trim()
            if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { $v = $Matches[1] }
            # Translate the handful of shell-isms the example file uses.
            $v = $v -replace '\$HOME', $env:USERPROFILE.Replace('\', '/')
            $c[$k] = $v
        }
    }

    foreach ($required in 'CP_IP', 'SSH_USER') {
        if (-not $c.ContainsKey($required) -or -not $c[$required]) {
            Die "lab.env is missing a value for $required"
        }
    }
    foreach ($kv in @{
        CP_NAME='k8s-cp'; SSH_PORT='22'; SSH_KEY=''; WORKERS=''
        K8S_MINOR='v1.31'; K8S_PKG_VERSION=''; CNI='calico'
        POD_CIDR='192.168.0.0/16'; SERVICE_CIDR='10.96.0.0/12'
        CALICO_VERSION='v3.28.2'; FLANNEL_VERSION='v0.25.6'; CILIUM_VERSION='1.16.3'
        METRICS_SERVER_VERSION='v0.7.2'; ETCDCTL_VERSION='v3.5.16'
        REMOTE_BACKUP_DIR='/opt/etcd-backups'; LOCAL_BACKUP_DIR='./backups'
        BACKUP_RETENTION='7'
    }.GetEnumerator()) {
        if (-not $c.ContainsKey($kv.Key) -or $c[$kv.Key] -eq '') { $c[$kv.Key] = $kv.Value }
    }

    # WORKERS="name:ip name:ip" -> a list of objects
    $c['WorkerList'] = @()
    foreach ($pair in ($c['WORKERS'] -split '\s+' | Where-Object { $_ })) {
        $parts = $pair -split ':'
        $c['WorkerList'] += [pscustomobject]@{ Name = $parts[0]; Ip = $parts[1] }
    }

    # SSH_KEY may be a POSIX-ish path; normalise it for Windows.
    if ($c['SSH_KEY']) {
        $c['SSH_KEY'] = $c['SSH_KEY'].Replace('/', '\')
        if ($c['SSH_KEY'].StartsWith('~')) {
            $c['SSH_KEY'] = $c['SSH_KEY'].Replace('~', $env:USERPROFILE)
        }
    }

    $Script:Cfg = $c
    return $c
}

function Get-AllNodes {
    $c = Import-LabEnv
    $nodes = @([pscustomobject]@{ Name = $c['CP_NAME']; Ip = $c['CP_IP']; Role = 'control-plane' })
    foreach ($w in $c['WorkerList']) {
        $nodes += [pscustomobject]@{ Name = $w.Name; Ip = $w.Ip; Role = 'worker' }
    }
    return $nodes
}

function Resolve-LabNode ($query) {
    $c = Import-LabEnv
    if ($query -in @('cp', 'control-plane', $c['CP_NAME'], $c['CP_IP'])) { return $c['CP_IP'] }
    foreach ($w in $c['WorkerList']) {
        if ($query -eq $w.Name -or $query -eq $w.Ip) { return $w.Ip }
    }
    if ($query -in @('worker', 'worker1', 'w1') -and $c['WorkerList'].Count -gt 0) {
        return $c['WorkerList'][0].Ip
    }
    Die "Unknown node '$query'"
}

# --------------------------------------------------------------------------
# SSH plumbing
# --------------------------------------------------------------------------
function Get-SshArgs {
    $c = Import-LabEnv
    $known = Join-Path $Script:RepoRoot '.known_hosts'
    $a = @(
        '-o', 'BatchMode=yes'
        '-o', 'StrictHostKeyChecking=accept-new'
        '-o', "UserKnownHostsFile=$known"
        '-o', 'ConnectTimeout=10'
        '-p', $c['SSH_PORT']
    )
    if ($c['SSH_KEY'] -and (Test-Path $c['SSH_KEY'])) { $a += @('-i', $c['SSH_KEY']) }
    return $a
}

# Invoke-Node <ip> <remote command string>
function Invoke-Node {
    param([string]$Ip, [string]$CommandLine, [switch]$Quiet)
    $c = Import-LabEnv
    $sshArgs = Get-SshArgs
    $target  = "$($c['SSH_USER'])@$Ip"
    if ($Quiet) {
        $out  = & ssh @sshArgs $target $CommandLine 2>&1
        $code = $LASTEXITCODE
        return @{ Output = @($out); Code = $code }
    }
    # Out-Host, not the pipeline: callers pipe our return value to Out-Null and
    # would otherwise swallow the remote command's output along with it.
    & ssh @sshArgs $target $CommandLine 2>&1 | Out-Host
    return @{ Output = @(); Code = $LASTEXITCODE }
}

# Invoke-NodeSudo <ip> <env string> <command> - run as root with env passed in.
# The command is single-quoted for the remote shell so PowerShell quoting on
# this side never leaks into bash on the other side.
function Invoke-NodeSudo {
    param([string]$Ip, [string]$EnvVars = '', [string]$CommandLine, [switch]$Quiet)
    $escaped = $CommandLine.Replace("'", "'\''")
    $full = "sudo $EnvVars bash -c '$escaped'"
    return Invoke-Node -Ip $Ip -CommandLine $full -Quiet:$Quiet
}

function Copy-ToNode {
    param([string]$Local, [string]$Ip, [string]$Remote)
    $c = Import-LabEnv
    $sshArgs = Get-SshArgs
    & scp @sshArgs -q -r $Local "$($c['SSH_USER'])@${Ip}:${Remote}"
    if ($LASTEXITCODE -ne 0) { Die "scp to $Ip failed" }
}

function Copy-FromNode {
    param([string]$Ip, [string]$Remote, [string]$Local)
    $c = Import-LabEnv
    $sshArgs = Get-SshArgs
    & scp @sshArgs -q "$($c['SSH_USER'])@${Ip}:${Remote}" $Local
    return $LASTEXITCODE
}

function Sync-Scripts ($Ip) {
    $r = Invoke-Node -Ip $Ip -CommandLine "rm -rf $Script:RemoteDir && mkdir -p $Script:RemoteDir" -Quiet
    if ($r.Code -ne 0) { Die "Cannot SSH to $Ip. Try: .\lab.ps1 ssh-setup" }
    Copy-ToNode -Local (Join-Path $Script:RepoRoot 'scripts') -Ip $Ip -Remote "$Script:RemoteDir/"
    Invoke-Node -Ip $Ip -CommandLine "chmod +x $Script:RemoteDir/scripts/node/*.sh $Script:RemoteDir/scripts/lib/*.sh" -Quiet | Out-Null
}

function Get-NodeEnv {
    $c = Import-LabEnv
    $parts = @(
        "K8S_MINOR='$($c['K8S_MINOR'])'"
        "K8S_PKG_VERSION='$($c['K8S_PKG_VERSION'])'"
        "CNI='$($c['CNI'])'"
        "POD_CIDR='$($c['POD_CIDR'])'"
        "SERVICE_CIDR='$($c['SERVICE_CIDR'])'"
        "CALICO_VERSION='$($c['CALICO_VERSION'])'"
        "FLANNEL_VERSION='$($c['FLANNEL_VERSION'])'"
        "CILIUM_VERSION='$($c['CILIUM_VERSION'])'"
        "METRICS_SERVER_VERSION='$($c['METRICS_SERVER_VERSION'])'"
        "ETCDCTL_VERSION='$($c['ETCDCTL_VERSION'])'"
    )
    return ($parts -join ' ')
}

function Get-HostsBlock {
    $lines = foreach ($n in Get-AllNodes) { "$($n.Ip) $($n.Name)" }
    return ($lines -join '\n')
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
function Cmd-Help {
@'
lab.ps1 - control CLI for the kubeadm lab (Windows host)

  SETUP
    .\lab.ps1 check              Validate lab.env and SSH reachability
    .\lab.ps1 ssh-setup          Create an SSH key and install it on all nodes
    .\lab.ps1 preflight          Read-only readiness checks on every node

  BUILD
    .\lab.ps1 up                 Full build: prep -> init -> CNI -> join -> verify
    .\lab.ps1 prep               Prepare every node
    .\lab.ps1 init               kubeadm init + CNI on the control plane
    .\lab.ps1 join [node]        Join a worker (default: all)
    .\lab.ps1 addons             metrics-server, local-path, helm, etcdctl

  OPERATE
    .\lab.ps1 status             One-screen cluster overview
    .\lab.ps1 verify             Full health check incl. a live smoke test
    .\lab.ps1 kubeconfig         Fetch admin.conf for local kubectl
    .\lab.ps1 ssh <node>         Interactive SSH into a node
    .\lab.ps1 run <node|all> ..  Run a command on one or all nodes
    .\lab.ps1 kubectl <args>     Run kubectl on the control plane

  BACKUP / RESTORE
    .\lab.ps1 backup [label]     Snapshot etcd and pull it to .\backups
    .\lab.ps1 backups            List snapshots remote and local
    .\lab.ps1 restore [file]     Restore etcd (default: newest snapshot)
    .\lab.ps1 dr-drill           Guided disaster-recovery exercise

  TROUBLESHOOT / TEARDOWN
    .\lab.ps1 diagnostics        Collect support bundles from every node
    .\lab.ps1 reset <node|all>   kubeadm reset back to a clean state
    .\lab.ps1 labs               List the hands-on exercises

  Other scripts in this folder:
    .\Setup-WindowsHost.ps1      Install OpenSSH, VirtualBox and kubectl
    .\New-LabVM.ps1              Create the worker VM in VirtualBox
'@ | Write-Host
}

function Cmd-Check {
    $c = Import-LabEnv
    Write-Head 'Configuration'
    Write-Info2 "control plane : $($c['CP_NAME']) ($($c['CP_IP']))"
    foreach ($w in $c['WorkerList']) { Write-Info2 "worker        : $($w.Name) ($($w.Ip))" }
    Write-Info2 "ssh           : $($c['SSH_USER'])@... port $($c['SSH_PORT'])"
    Write-Info2 "kubernetes    : $($c['K8S_MINOR'])"
    Write-Info2 "cni / podCIDR : $($c['CNI']) / $($c['POD_CIDR'])"

    Write-Head 'Local tooling'
    foreach ($tool in 'ssh', 'scp') {
        if (Get-Command $tool -ErrorAction SilentlyContinue) { Write-Ok "$tool found" }
        else { Write-Bad "$tool missing - run .\Setup-WindowsHost.ps1"; }
    }
    if (Get-Command kubectl -ErrorAction SilentlyContinue) { Write-Ok 'kubectl found' }
    else { Write-Warn2 'kubectl not installed locally - .\lab.ps1 kubectl still works over SSH' }

    Write-Head 'Node reachability'
    $failed = $false
    foreach ($n in Get-AllNodes) {
        $r = Invoke-Node -Ip $n.Ip -CommandLine 'hostname' -Quiet
        $line = '  {0,-16} {1,-16} {2,-14} ' -f $n.Name, $n.Ip, $n.Role
        if ($r.Code -eq 0) {
            $remote = "$($r.Output | Select-Object -First 1)".Trim()
            if ($remote -eq $n.Name) { Write-Host "$line SSH ok" -ForegroundColor Green }
            else { Write-Host "$line SSH ok (hostname is '$remote')" -ForegroundColor Yellow }
        } else {
            Write-Host "$line unreachable" -ForegroundColor Red
            $failed = $true
        }
    }
    Write-Host ''
    if ($failed) {
        Write-Bad 'At least one node is unreachable over SSH.'
        Write-Info2 'Fix with: .\lab.ps1 ssh-setup   (or check the IPs in lab.env)'
        exit 1
    }
    Write-Ok 'Everything checks out. Next: .\lab.ps1 preflight'
}

function Cmd-SshSetup {
    $c = Import-LabEnv
    $key = $c['SSH_KEY']
    if (-not $key) { Die 'Set SSH_KEY in lab.env first.' }

    Write-Head 'SSH key'
    if (Test-Path $key) {
        Write-Skip "Key already exists: $key"
    } else {
        $dir = Split-Path -Parent $key
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # '""' is the documented Windows workaround for an empty passphrase:
        # a bare '' is dropped before ssh-keygen ever sees it.
        & ssh-keygen -t ed25519 -N '""' -C "k8s-lab@$env:COMPUTERNAME" -f $key
        if ($LASTEXITCODE -ne 0) { Die 'ssh-keygen failed' }
        Write-Ok "Created $key"
    }

    Write-Head 'Installing the public key on each node'
    Write-Info2 "You will be asked for the $($c['SSH_USER']) password once per node."
    $pub = (Get-Content "$key.pub" -Raw).Trim()
    foreach ($n in Get-AllNodes) {
        Write-Host ''
        Write-Step "$($n.Name) ($($n.Ip))"
        # Windows has no ssh-copy-id, so append the key over an interactive session.
        $remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " +
                     "grep -qxF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; " +
                     "chmod 600 ~/.ssh/authorized_keys && echo INSTALLED"
        $known   = Join-Path $Script:RepoRoot '.known_hosts'
        $copyArgs = @('-o', 'StrictHostKeyChecking=accept-new',
                      '-o', "UserKnownHostsFile=$known",
                      '-p', $c['SSH_PORT'])
        & ssh @copyArgs "$($c['SSH_USER'])@$($n.Ip)" $remoteCmd
        if ($LASTEXITCODE -eq 0) { Write-Ok "Key installed on $($n.Name)" }
        else { Write-Bad "Failed on $($n.Name)" }
    }
    Write-Host ''
    Write-Ok 'Done. Verify with: .\lab.ps1 check'
}

function Cmd-Preflight {
    $nodes = Get-AllNodes
    $peers = ($nodes | ForEach-Object { $_.Ip }) -join ' '
    $rc = 0
    foreach ($n in $nodes) {
        Write-Head "Preflight: $($n.Name) ($($n.Ip), $($n.Role))"
        Sync-Scripts $n.Ip
        $r = Invoke-NodeSudo -Ip $n.Ip -EnvVars "ROLE='$($n.Role)' PEER_IPS='$peers'" `
             -CommandLine "$Script:RemoteDir/scripts/node/01-preflight.sh"
        if ($r.Code -ne 0) { $rc = 1 }
    }
    Write-Host ''
    if ($rc -ne 0) { Die 'Preflight failed on at least one node.' }
    Write-Ok 'All nodes passed preflight. Next: .\lab.ps1 up'
}

function Cmd-Prep {
    $c = Import-LabEnv
    $hosts = Get-HostsBlock
    foreach ($n in Get-AllNodes) {
        Write-Head "Preparing $($n.Name) ($($n.Ip), $($n.Role))"
        Sync-Scripts $n.Ip
        $fw = if ($env:FIREWALL_MODE) { $env:FIREWALL_MODE } else { 'open-ports' }
        $e = "$(Get-NodeEnv) NODE_NAME='$($n.Name)' ROLE='$($n.Role)' HOSTS_ENTRIES='$hosts' " +
             "FIREWALL_MODE='$fw' SSH_PORT_ON_NODE='$($c['SSH_PORT'])'"
        foreach ($s in '02-prep-node.sh', '03-install-containerd.sh', '04-install-kube-tools.sh') {
            $r = Invoke-NodeSudo -Ip $n.Ip -EnvVars $e -CommandLine "$Script:RemoteDir/scripts/node/$s"
            if ($r.Code -ne 0) { Die "$s failed on $($n.Name)" }
        }
        Write-Ok "$($n.Name) prepared"
    }
    Write-Host ''
    Write-Ok 'Every node is prepared. Next: .\lab.ps1 init'
}

function Cmd-Init {
    $c = Import-LabEnv
    Write-Head "Initialising the control plane on $($c['CP_NAME']) ($($c['CP_IP']))"
    Sync-Scripts $c['CP_IP']
    $e = "$(Get-NodeEnv) NODE_NAME='$($c['CP_NAME'])' APISERVER_IP='$($c['CP_IP'])' ASSUME_YES=1"
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] -EnvVars $e -CommandLine "$Script:RemoteDir/scripts/node/10-init-control-plane.sh"
    if ($r.Code -ne 0) { Die 'kubeadm init failed' }

    Write-Head "Installing the pod network ($($c['CNI']))"
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] -EnvVars (Get-NodeEnv) -CommandLine "$Script:RemoteDir/scripts/node/11-install-cni.sh"
    if ($r.Code -ne 0) { Die 'CNI install failed' }

    Cmd-Kubeconfig
    Write-Host ''
    Write-Ok 'Control plane is up. Next: .\lab.ps1 join'
}

function Cmd-Addons {
    $c = Import-LabEnv
    Write-Head "Installing add-ons on $($c['CP_NAME'])"
    Sync-Scripts $c['CP_IP']
    Invoke-NodeSudo -Ip $c['CP_IP'] -EnvVars (Get-NodeEnv) `
        -CommandLine "$Script:RemoteDir/scripts/node/13-install-addons.sh" | Out-Null
}

function Cmd-Join ($target) {
    $c = Import-LabEnv
    if (-not $target) { $target = 'all' }

    Write-Head "Fetching a fresh join command from $($c['CP_NAME'])"
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] -CommandLine 'kubeadm token create --print-join-command' -Quiet
    $joinCmd = "$($r.Output | Where-Object { $_ -match '^kubeadm join' } | Select-Object -First 1)".Trim()
    if (-not $joinCmd) { Die 'Could not get a join command. Is the control plane initialised?' }
    Write-Ok 'Token issued (valid 24h)'

    $joined = 0
    foreach ($w in $c['WorkerList']) {
        if ($target -ne 'all' -and $target -ne $w.Name -and $target -ne $w.Ip) { continue }
        Write-Head "Joining $($w.Name) ($($w.Ip))"
        Sync-Scripts $w.Ip
        $e = "ASSUME_YES=1 NODE_IP='$($w.Ip)' JOIN_CMD='$joinCmd'"
        $res = Invoke-NodeSudo -Ip $w.Ip -EnvVars $e -CommandLine "$Script:RemoteDir/scripts/node/12-join-worker.sh"
        if ($res.Code -ne 0) { Die "join failed on $($w.Name)" }
        $joined++
    }
    if ($joined -eq 0) { Die "No matching worker for '$target'." }

    Write-Head 'Waiting for nodes to report Ready'
    for ($i = 0; $i -lt 40; $i++) {
        $r = Invoke-NodeSudo -Ip $c['CP_IP'] `
             -CommandLine 'KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers' -Quiet
        if ($r.Code -eq 0 -and -not ($r.Output | Where-Object { $_ -notmatch '\sReady\s' })) { break }
        Start-Sleep -Seconds 10
    }
    Cmd-Kubectl @('get', 'nodes', '-o', 'wide')
    Write-Host ''
    Write-Ok 'Workers joined. Next: .\lab.ps1 verify'
}

function Cmd-Up {
    Write-Head 'Building the whole lab'
    Write-Info2 'This runs preflight -> prep -> init -> CNI -> add-ons -> join -> verify.'
    Write-Info2 'Expect 10-20 minutes on a typical home LAN.'
    if (-not (Confirm-Action 'Start?')) { Write-Info2 'Aborted.'; return }
    Cmd-Preflight; Cmd-Prep; Cmd-Init; Cmd-Addons; Cmd-Join 'all'; Cmd-Verify
    Write-Host ''
    Write-Ok 'Lab is ready. Try:  .\lab.ps1 status   then  .\lab.ps1 labs'
}

function Cmd-Verify {
    $c = Import-LabEnv
    Sync-Scripts $c['CP_IP']
    Invoke-NodeSudo -Ip $c['CP_IP'] -EnvVars 'SMOKE=1' `
        -CommandLine "$Script:RemoteDir/scripts/node/20-verify-cluster.sh" | Out-Null
}

function Cmd-Kubectl ($kargs) {
    $c = Import-LabEnv
    $joined = ($kargs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    Invoke-NodeSudo -Ip $c['CP_IP'] -CommandLine "KUBECONFIG=/etc/kubernetes/admin.conf kubectl $joined" | Out-Null
}

function Cmd-Kubeconfig {
    $c = Import-LabEnv
    $dest = Join-Path $Script:RepoRoot 'kubeconfig'
    Write-Head 'Fetching kubeconfig'
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] -CommandLine 'cat /etc/kubernetes/admin.conf' -Quiet
    if ($r.Code -ne 0 -or -not $r.Output) { Die 'Could not read admin.conf on the control plane.' }
    $text = ($r.Output -join "`n") -replace 'server: https://[^:\s]+:6443', "server: https://$($c['CP_IP']):6443"
    Set-Content -Path $dest -Value $text -Encoding ascii
    Write-Ok "Wrote $dest"
    Write-Info2 'Use it from this machine with:'
    Write-Info2 "  `$env:KUBECONFIG = '$dest'"
    Write-Info2 '  kubectl get nodes'
}

function Cmd-Status {
    Write-Head 'Nodes';        Cmd-Kubectl @('get','nodes','-o','wide')
    Write-Head 'System pods';  Cmd-Kubectl @('get','pods','-n','kube-system','-o','wide')
    Write-Head 'Workloads';    Cmd-Kubectl @('get','deploy,sts,ds','-A')
    Write-Head 'Recent events';Cmd-Kubectl @('get','events','-A','--sort-by=.lastTimestamp')
}

function Cmd-Backup ($label) {
    $c = Import-LabEnv
    Write-Head "Taking an etcd snapshot on $($c['CP_NAME'])"
    Sync-Scripts $c['CP_IP']
    $e = "BACKUP_DIR='$($c['REMOTE_BACKUP_DIR'])' RETENTION='$($c['BACKUP_RETENTION'])' LABEL='$label'"
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] -EnvVars $e -CommandLine "$Script:RemoteDir/scripts/node/30-etcd-backup.sh"
    if ($r.Code -ne 0) { Die 'Backup failed' }

    Write-Head 'Pulling the snapshot to this machine'
    $localDir = Join-Path $Script:RepoRoot 'backups'
    if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] `
         -CommandLine "ls -1t $($c['REMOTE_BACKUP_DIR'])/etcd-snapshot-*.db | head -1" -Quiet
    $newest = "$($r.Output | Select-Object -First 1)".Trim()
    if (-not $newest) { Die 'No snapshot found on the control plane.' }
    $base = Split-Path -Leaf $newest

    # Snapshots are root-owned 0600, so stage a readable copy before scp.
    Invoke-NodeSudo -Ip $c['CP_IP'] `
        -CommandLine "cp $newest ${newest}.sha256 ${newest}.meta /tmp/ && chown $($c['SSH_USER']) /tmp/$base*" -Quiet | Out-Null
    foreach ($suffix in '', '.sha256', '.meta') {
        Copy-FromNode -Ip $c['CP_IP'] -Remote "/tmp/$base$suffix" -Local $localDir | Out-Null
    }
    Invoke-NodeSudo -Ip $c['CP_IP'] -CommandLine "rm -f /tmp/$base*" -Quiet | Out-Null

    $localFile = Join-Path $localDir $base
    if ((Test-Path $localFile) -and (Test-Path "$localFile.sha256")) {
        $want = ((Get-Content "$localFile.sha256" -Raw) -split '\s+')[0]
        $have = (Get-FileHash -Algorithm SHA256 $localFile).Hash.ToLower()
        if ($want -eq $have) { Write-Ok 'Checksum verified after transfer' }
        else { Die 'Checksum mismatch after transfer!' }
    }
    Write-Ok "Local copy: $localFile"
    Get-ChildItem $localDir | Format-Table Name, Length, LastWriteTime | Out-String | Write-Host
}

function Cmd-Backups {
    $c = Import-LabEnv
    Write-Head "On the control plane ($($c['REMOTE_BACKUP_DIR']))"
    Invoke-NodeSudo -Ip $c['CP_IP'] `
        -CommandLine "ls -lh $($c['REMOTE_BACKUP_DIR'])/etcd-snapshot-*.db 2>/dev/null || echo '(none)'" | Out-Null
    Write-Head 'Local (.\backups)'
    $localDir = Join-Path $Script:RepoRoot 'backups'
    if (Test-Path $localDir) { Get-ChildItem $localDir -Filter *.db | Format-Table Name, Length, LastWriteTime | Out-String | Write-Host }
    else { Write-Info2 '(none)' }
}

function Cmd-Restore ($snap) {
    $c = Import-LabEnv
    if (-not $snap) { $snap = '--latest' }
    Write-Head "Restoring etcd on $($c['CP_NAME'])"
    Sync-Scripts $c['CP_IP']

    # A local path means "upload this snapshot first, then restore from it".
    if ($snap -ne '--latest' -and (Test-Path $snap)) {
        $base = Split-Path -Leaf $snap
        Write-Info2 "Uploading $base to the control plane"
        Copy-ToNode -Local $snap -Ip $c['CP_IP'] -Remote "/tmp/$base"
        if (Test-Path "$snap.sha256") { Copy-ToNode -Local "$snap.sha256" -Ip $c['CP_IP'] -Remote "/tmp/$base.sha256" }
        Invoke-NodeSudo -Ip $c['CP_IP'] `
            -CommandLine "mkdir -p $($c['REMOTE_BACKUP_DIR']) && mv /tmp/$base* $($c['REMOTE_BACKUP_DIR'])/ && chown root:root $($c['REMOTE_BACKUP_DIR'])/$base*" -Quiet | Out-Null
        $snap = "$($c['REMOTE_BACKUP_DIR'])/$base"
    }

    $yes = if ($env:ASSUME_YES -eq '1') { '1' } else { '0' }
    $e = "ASSUME_YES=$yes BACKUP_DIR='$($c['REMOTE_BACKUP_DIR'])'"
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] -EnvVars $e `
         -CommandLine "$Script:RemoteDir/scripts/node/31-etcd-restore.sh '$snap'"
    if ($r.Code -ne 0) { Die 'Restore failed' }
    Write-Host ''
    Write-Ok 'Restore finished. Verifying...'
    Cmd-Kubectl @('get', 'nodes')
}

function Cmd-DrDrill {
@'

  DISASTER-RECOVERY DRILL
  =======================
  This walks the full backup -> destroy -> restore cycle on your live lab:
    1. Deploy a marker workload  (namespace: dr-drill)
    2. Take a labelled etcd snapshot
    3. Delete the namespace, simulating an accidental kubectl delete
    4. Restore etcd from the snapshot
    5. Prove the workload came back

'@ | Write-Host
    if (-not (Confirm-Action 'Run the drill?')) { Write-Info2 'Aborted.'; return }

    Write-Head '1/5  Create the marker workload'
    Cmd-Kubectl @('create','namespace','dr-drill')
    Cmd-Kubectl @('-n','dr-drill','create','deployment','marker','--image=nginx:stable-alpine','--replicas=2')
    Cmd-Kubectl @('-n','dr-drill','rollout','status','deploy/marker','--timeout=180s')

    Write-Head '2/5  Snapshot etcd'
    Cmd-Backup 'dr-drill'

    Write-Head '3/5  Simulate the disaster'
    Write-Warn2 'Deleting namespace dr-drill...'
    Cmd-Kubectl @('delete','namespace','dr-drill','--wait=true')

    Write-Head '4/5  Restore'
    $env:ASSUME_YES = '1'
    Cmd-Restore '--latest'
    $env:ASSUME_YES = '0'

    Write-Head '5/5  Verify recovery'
    Start-Sleep -Seconds 15
    $c = Import-LabEnv
    $r = Invoke-NodeSudo -Ip $c['CP_IP'] `
         -CommandLine 'KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n dr-drill get deploy marker' -Quiet
    if ($r.Code -eq 0) {
        Cmd-Kubectl @('get','all','-n','dr-drill')
        Write-Host ''
        Write-Ok 'DRILL PASSED - the deleted namespace came back from the snapshot.'
        Write-Info2 'Clean up when done:  .\lab.ps1 kubectl delete ns dr-drill'
    } else {
        Write-Bad 'DRILL FAILED - dr-drill did not come back.'
        exit 1
    }
}

function Cmd-Diagnostics {
    $out = Join-Path $Script:RepoRoot 'diagnostics'
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $c = Import-LabEnv
    foreach ($n in Get-AllNodes) {
        Write-Head "Collecting from $($n.Name) ($($n.Ip))"
        Sync-Scripts $n.Ip
        $r = Invoke-NodeSudo -Ip $n.Ip -EnvVars 'OUT_DIR=/tmp' `
             -CommandLine "$Script:RemoteDir/scripts/node/99-diagnostics.sh" -Quiet
        $tar = ($r.Output | Select-String -Pattern '/tmp/diagnostics-\S+\.tar\.gz' -AllMatches |
                ForEach-Object { $_.Matches.Value } | Select-Object -First 1)
        if ($tar) {
            Invoke-NodeSudo -Ip $n.Ip -CommandLine "chown $($c['SSH_USER']) $tar" -Quiet | Out-Null
            Copy-FromNode -Ip $n.Ip -Remote $tar -Local $out | Out-Null
            Invoke-NodeSudo -Ip $n.Ip -CommandLine "rm -f $tar" -Quiet | Out-Null
            Write-Ok "Saved $(Split-Path -Leaf $tar)"
        } else {
            Write-Warn2 "No bundle produced on $($n.Name)"
        }
    }
    Write-Host ''
    Get-ChildItem $out | Format-Table Name, Length, LastWriteTime | Out-String | Write-Host
    Write-Ok "Bundles in $out"
}

function Cmd-Reset ($target) {
    if (-not $target) { Die 'Usage: .\lab.ps1 reset <node|all>' }
    Write-Host ''
    Write-Warn2 "This destroys the Kubernetes installation on: $target"
    if (-not (Confirm-Action 'Are you sure?')) { Write-Info2 'Aborted.'; return }

    $c = Import-LabEnv
    $targets = if ($target -eq 'all') {
        @($c['WorkerList'] | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Ip = $_.Ip } }) +
        @([pscustomobject]@{ Name = $c['CP_NAME']; Ip = $c['CP_IP'] })
    } else {
        @([pscustomobject]@{ Name = $target; Ip = (Resolve-LabNode $target) })
    }
    foreach ($t in $targets) {
        Write-Head "Resetting $($t.Name)"
        Sync-Scripts $t.Ip
        Invoke-NodeSudo -Ip $t.Ip -EnvVars 'ASSUME_YES=1' `
            -CommandLine "$Script:RemoteDir/scripts/node/90-reset-node.sh" | Out-Null
    }
    Write-Host ''
    Write-Ok 'Reset complete. Rebuild with: .\lab.ps1 up'
}

function Cmd-Ssh ($node) {
    $c = Import-LabEnv
    if (-not $node) { $node = 'cp' }
    $ip = Resolve-LabNode $node
    $a = @('-o', 'StrictHostKeyChecking=accept-new',
           '-o', "UserKnownHostsFile=$(Join-Path $Script:RepoRoot '.known_hosts')",
           '-p', $c['SSH_PORT'])
    if ($c['SSH_KEY'] -and (Test-Path $c['SSH_KEY'])) { $a += @('-i', $c['SSH_KEY']) }
    & ssh @a "$($c['SSH_USER'])@$ip"
}

function Cmd-Run ($rest) {
    if ($rest.Count -lt 2) { Die 'Usage: .\lab.ps1 run <node|all> <command...>' }
    $target = $rest[0]
    $cmdLine = ($rest[1..($rest.Count - 1)]) -join ' '
    if ($target -eq 'all') {
        foreach ($n in Get-AllNodes) {
            Write-Head "$($n.Name) ($($n.Ip))"
            Invoke-Node -Ip $n.Ip -CommandLine $cmdLine | Out-Null
        }
    } else {
        Invoke-Node -Ip (Resolve-LabNode $target) -CommandLine $cmdLine | Out-Null
    }
}

function Cmd-Labs {
    Write-Head 'Hands-on exercises in .\labs'
    foreach ($d in Get-ChildItem (Join-Path $Script:RepoRoot 'labs') -Directory) {
        $readme = Join-Path $d.FullName 'README.md'
        $title = ''
        if (Test-Path $readme) {
            $title = (Get-Content $readme -TotalCount 3 | Where-Object { $_ -match '^# ' } |
                      Select-Object -First 1) -replace '^# ', ''
        }
        Write-Host ('  {0,-28} {1}' -f $d.Name, $title)
    }
    Write-Host ''
    Write-Info2 'Start one with:  Get-Content .\labs\01-workloads\README.md'
}

# --------------------------------------------------------------------------
switch ($Command.ToLower()) {
    'help'        { Cmd-Help }
    '-h'          { Cmd-Help }
    '--help'      { Cmd-Help }
    'check'       { Cmd-Check }
    'ssh-setup'   { Cmd-SshSetup }
    'preflight'   { Cmd-Preflight }
    'prep'        { Cmd-Prep }
    'init'        { Cmd-Init }
    'addons'      { Cmd-Addons }
    'join'        { Cmd-Join ($Rest | Select-Object -First 1) }
    'up'          { Cmd-Up }
    'verify'      { Cmd-Verify }
    'status'      { Cmd-Status }
    'kubeconfig'  { Cmd-Kubeconfig }
    'kubectl'     { Cmd-Kubectl $Rest }
    'k'           { Cmd-Kubectl $Rest }
    'backup'      { Cmd-Backup ($Rest | Select-Object -First 1) }
    'backups'     { Cmd-Backups }
    'restore'     { Cmd-Restore ($Rest | Select-Object -First 1) }
    'dr-drill'    { Cmd-DrDrill }
    'diagnostics' { Cmd-Diagnostics }
    'reset'       { Cmd-Reset ($Rest | Select-Object -First 1) }
    'ssh'         { Cmd-Ssh ($Rest | Select-Object -First 1) }
    'run'         { Cmd-Run $Rest }
    'labs'        { Cmd-Labs }
    default       { Write-Bad "Unknown command: $Command"; Write-Host ''; Cmd-Help; exit 1 }
}
