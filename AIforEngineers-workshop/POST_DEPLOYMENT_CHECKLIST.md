# Azure Terraform Lab — Post-Deployment Readiness Checklist
**Environment:** Azure Ubuntu 22.04 Lab  
**Deployment Date:** [Record deployment timestamp]  
**Validator:** [Compute Engineer Name]  
**Resource Group:** `rg-ailab-{participant_name}`

---

## ⚡ PRIORITY CHECKS — SECURITY & CONNECTIVITY

### 1. SECURITY: NSG Rules Enforcement — SSH Access Restriction

**Category:** SECURITY  
**Check:** Verify SSH (port 22) is ONLY accessible from Bastion subnet (10.0.3.0/27), NOT from internet

**Command:**
```bash
az network nsg rule list \
  --resource-group "rg-ailab-{participant_name}" \
  --nsg-name "nsg-app" \
  --query "[?name=='AllowSSH'].{name:name, sourceAddressPrefix:sourceAddressPrefix, destinationPortRange:destinationPortRange, access:access}" \
  -o table
```

**Expected Output:**
```
Name      SourceAddressPrefix  DestinationPortRange  Access
--------  ------------------  -------------------  ------
AllowSSH  10.0.3.0/27          22                    Allow
```

**FAIL Condition:** Source prefix is NOT `10.0.3.0/27`, or rule shows `*` or `0.0.0.0/0`  
**Tower Note:** **CRITICAL for compute security posture.** SSH restricted to Bastion-only access eliminates direct internet exposure. Compute engineers must validate this before admitting any workloads. Misconfiguration = immediate container escape risk or lateral movement from compromised VMs.

---

### 2. SECURITY: RDP Access Control — Windows VM Isolation

**Category:** SECURITY  
**Check:** Confirm RDP (port 3389) restricted to Bastion subnet only

**Command:**
```bash
az network nsg rule list \
  --resource-group "rg-ailab-{participant_name}" \
  --nsg-name "nsg-app" \
  --query "[?name=='AllowRDP'].{name:name, sourceAddressPrefix:sourceAddressPrefix, destinationPortRange:destinationPortRange}" \
  -o table
```

**Expected Output:**
```
Name      SourceAddressPrefix  DestinationPortRange
--------  ------------------  -------------------
AllowRDP  10.0.3.0/27          3389
```

**FAIL Condition:** Any RDP rule permitting access from internet (0.0.0.0/0) or broad ranges  
**Tower Note:** Windows VM security depends entirely on this perimeter control. RDP is a high-value target; Bastion-only enforcement is table-stakes for compute hardening.

---

### 3. CONNECTIVITY: Bastion Host Accessibility

**Category:** CONNECTIVITY  
**Check:** Verify Azure Bastion is deployed and healthy

**Command:**
```bash
az network bastion list \
  --resource-group "rg-ailab-{participant_name}" \
  --query "[].{name:name, provisioningState:provisioningState, scaleUnits:scaleUnits}" \
  -o table
```

**Expected Output:**
```
Name           ProvisioningState  ScaleUnits
-------------  ----------------  ----------
bastion-ailab  Succeeded          2
```

**FAIL Condition:** `ProvisioningState` is NOT `Succeeded`, or Bastion instance missing  
**Tower Note:** Bastion is the **only attack surface** for this network. If it's unavailable, compute engineers cannot manage any VMs. Provision health is the gating factor for all downstream ops.

---

### 4. CONNECTIVITY: VM Network Interface Validation

**Category:** CONNECTIVITY  
**Check:** Confirm all three VMs have correct private IPs and NSG associations

**Command:**
```bash
az network nic list \
  --resource-group "rg-ailab-{participant_name}" \
  --query "[].{name:name, vmName:virtualMachine.id | split('/') | [-1], privateIP:ipConfigurations[0].privateIpAddress, nsg:networkSecurityGroup.id | split('/') | [-1]}" \
  -o table
```

**Expected Output:**
```
Name      VmName    PrivateIP    Nsg
--------  --------  -----------  -------
nic-app   vm-app    10.0.1.10    nsg-app
nic-db    vm-db     10.0.2.10    nsg-db
nic-win   vm-win    10.0.1.20    nsg-app
```

**FAIL Condition:** Any IP mismatched, NSG associations missing, or NICs in failed state  
**Tower Note:** Incorrect private IPs or NSG misconfiguration break inter-VM communication and access paths. Compute must verify at least once post-deployment before load-balancing or failover config.

---

### 5. SECURITY: Database Subnet Isolation

**Category:** SECURITY  
**Check:** Verify PostgreSQL (port 5432) accessible ONLY from app subnet (10.0.1.0/24)

**Command:**
```bash
az network nsg rule list \
  --resource-group "rg-ailab-{participant_name}" \
  --nsg-name "nsg-db" \
  --query "[?name=='AllowPostgres'].{sourceAddressPrefix:sourceAddressPrefix, destinationPortRange:destinationPortRange, protocol:protocol}" \
  -o table
```

**Expected Output:**
```
SourceAddressPrefix  DestinationPortRange  Protocol
------------------  -------------------  --------
10.0.1.0/24          5432                  Tcp
```

**FAIL Condition:** Source is `*` or `0.0.0.0/0`; rule allows broader CIDR than 10.0.1.0/24  
**Tower Note:** Database tier is high-value target. Restricting ingress to app-subnet-only prevents direct attacker access if app VMs compromised. This is the critical defense-in-depth layer for compute workloads.

---

### 6. SECURITY: Storage Account Public Access Disabled

**Category:** SECURITY  
**Check:** Confirm storage account blocks public access and enforces HTTPS

**Command:**
```bash
az storage account show \
  --resource-group "rg-ailab-{participant_name}" \
  --name "stailab{participant_name}" \
  --query "{allowBlobPublicAccess:allowBlobPublicAccess, httpsTrafficOnly:httpsTrafficOnly, minimumTlsVersion:minimumTlsVersion}" \
  -o table
```

**Expected Output:**
```
AllowBlobPublicAccess  HttpsTrafficOnly  MinimumTlsVersion
--------------------  ---------------  -----------------
false                  true             TLS1_2
```

**FAIL Condition:** `allowBlobPublicAccess` is `true`, or `httpsTrafficOnly` is `false`  
**Tower Note:** Boot diagnostics write VM logs to this storage. Public access = credential leakage + debug info disclosure. TLS 1.2+ requirement prevents downgrade attacks and is now baseline for Azure compliance.

---

### 7. CONNECTIVITY: Network Peering / VPN Status (if applicable)

**Category:** CONNECTIVITY  
**Check:** List all VNet peerings and confirm expected state

**Command:**
```bash
az network vnet peering list \
  --resource-group "rg-ailab-{participant_name}" \
  --vnet-name "vnet-ailab" \
  -o table
```

**Expected Output:**
```
(Empty table if no peerings required, or list of peerings in "Connected" state)
```

**FAIL Condition:** Peering exists but is in `InitiatedByRemote` or `Disconnected` state  
**Tower Note:** If lab requires multi-VNet comms (e.g., hybrid cloud), peering failures silently break inter-site traffic. Compute should verify before declaring environment ready.

---

## 📊 MONITORING & OBSERVABILITY

### 8. MONITORING: Boot Diagnostics Enabled

**Category:** MONITORING  
**Check:** Confirm boot diagnostics configured on all three VMs

**Command:**
```bash
az vm boot-diagnostics get-boot-log \
  --name vm-app \
  --resource-group "rg-ailab-{participant_name}" \
  --query "consoleLogBlobUri" 2>/dev/null && echo "✓ Boot diagnostics active on vm-app" || echo "✗ Boot diagnostics check failed"

az vm boot-diagnostics get-boot-log \
  --name vm-db \
  --resource-group "rg-ailab-{participant_name}" \
  --query "consoleLogBlobUri" 2>/dev/null && echo "✓ Boot diagnostics active on vm-db" || echo "✗ Boot diagnostics check failed"

az vm boot-diagnostics get-boot-log \
  --name vm-win \
  --resource-group "rg-ailab-{participant_name}" \
  --query "consoleLogBlobUri" 2>/dev/null && echo "✓ Boot diagnostics active on vm-win" || echo "✗ Boot diagnostics check failed"
```

**Expected Output:**
```
https://stailab{participant_name}.blob.core.windows.net/bootdiagnostics-xxxx
✓ Boot diagnostics active on vm-app
(similar for vm-db and vm-win)
```

**FAIL Condition:** `consoleLogBlobUri` missing or HTTP 404 on blob endpoint  
**Tower Note:** Boot diagnostics are the **first resort** for unresponsive VM troubleshooting. Missing this blocks RCA on startup failures and kernel panics. Compute must have visibility into early-boot state.

---

### 9. MONITORING: VM Extension Status

**Category:** MONITORING  
**Check:** Verify critical extensions deployed (Azure Monitor Agent or DSC agents)

**Command:**
```bash
az vm extension list \
  --resource-group "rg-ailab-{participant_name}" \
  --vm-name vm-app \
  --query "[].{name:name, provisioningState:provisioningState}" \
  -o table

az vm extension list \
  --resource-group "rg-ailab-{participant_name}" \
  --vm-name vm-db \
  --query "[].{name:name, provisioningState:provisioningState}" \
  -o table

az vm extension list \
  --resource-group "rg-ailab-{participant_name}" \
  --vm-name vm-win \
  --query "[].{name:name, provisioningState:provisioningState}" \
  -o table
```

**Expected Output:**
```
(If Azure Monitor Agent deployed:)
Name                         ProvisioningState
-----------------------------  -----------------
AzureMonitorLinuxAgent       Succeeded
(or WindowsAgent for vm-win)

(Or if no extensions configured, all outputs will be empty — acceptable for base config)
```

**FAIL Condition:** Extension shows `Failed` or `ProvisioningState: Creating` (hanging)  
**Tower Note:** Extensions block startup if they fail. Broken agents prevent metrics collection and remote script execution. Must be resolved before VMs considered production-ready.

---

### 10. MONITORING: Storage Account Soft-Delete Configuration

**Category:** BACKUP  
**Check:** Confirm soft-delete retention is 7 days (matches Terraform `delete_retention_policy`)

**Command:**
```bash
az storage blob service-properties delete-policy show \
  --account-name "stailab{participant_name}" \
  --resource-group "rg-ailab-{participant_name}" \
  --query "{enabled:enabled, days:days}" \
  -o json
```

**Expected Output:**
```json
{
  "enabled": true,
  "days": 7
}
```

**FAIL Condition:** `enabled: false` or `days` not set to 7  
**Tower Note:** Boot diagnostic logs (VM startup records) live in this storage. 7-day retention provides a narrow RCA window; compute must not delete this without approval. Soft-delete prevents accidental wipe of audit trails.

---

## 🔄 CONNECTIVITY & SERVICE VALIDATION

### 11. CONNECTIVITY: VM-to-VM Network Path Validation (Linux → Windows)

**Category:** CONNECTIVITY  
**Check:** SSH into vm-app via Bastion, then test connectivity to vm-win (10.0.1.20:3389)

**Command (run from vm-app, accessible via Bastion portal):**
```bash
# First, connect to vm-app via Azure Bastion through portal
# Then run:
telnet 10.0.1.20 3389
# Or:
nc -zv 10.0.1.20 3389
```

**Expected Output:**
```
Connection to 10.0.1.20 port 3389 [tcp/ms-wbt-server] succeeded!
```

**FAIL Condition:** Connection timeout or refused (connection refused)  
**Tower Note:** This validates inter-VM routing and NSG rule application. Failure here indicates misconfigured routes or incorrect NSG association. Critical for multi-tier workload deployment.

---

### 12. CONNECTIVITY: VM-to-Database Network Path (App → DB)

**Category:** CONNECTIVITY  
**Check:** From vm-app, verify TCP connectivity to PostgreSQL on vm-db (10.0.2.10:5432)

**Command (run from vm-app via Bastion):**
```bash
nc -zv 10.0.2.10 5432
# Or using psql if available:
psql -h 10.0.2.10 -U labadmin -d postgres -c "SELECT version();" 2>&1 | head -5
```

**Expected Output:**
```
Connection to 10.0.2.10 port 5432 [tcp/postgresql] succeeded!
# OR psql output showing PostgreSQL version (if credentials match cloud-init setup)
```

**FAIL Condition:** Connection timeout, refused, or "host unreachable"  
**Tower Note:** App-to-DB connectivity is blocking for all data-driven workloads. Network failure here triggers all downstream app failures. Compute must validate before application deployment.

---

### 13. CONNECTIVITY: Linux VM SSH Key Acceptance

**Category:** CONNECTIVITY  
**Check:** Verify SSH is accepting connections and fingerprints are stable

**Command (from local machine via Bastion):**
```bash
# Via Bastion portal or local SSH client pointed to Bastion:
ssh -v labadmin@<bastion_IP_or_hostname> 2>&1 | grep -i "authentication succeeded\|permission denied"
# Or from within Bastion subnet:
ssh-keyscan -t rsa 10.0.1.10 >> ~/.ssh/known_hosts 2>&1
```

**Expected Output:**
```
10.0.1.10 ssh-rsa AAAAB3NzaC1yc2E... (public key added to known_hosts)
# OR in verbose mode:
Authentication succeeded (password based).
```

**FAIL Condition:** SSH connection timeout, host key mismatch, or "Connection refused"  
**Tower Note:** Bastion-based SSH access is the **only entry point**. Key negotiation failures block all Linux VM access. Fingerprint instability suggests VM image inconsistency (e.g., multiple clones with same key).

---

## 💾 BACKUP & DISASTER RECOVERY

### 14. BACKUP: Auto-Shutdown Schedules Enabled

**Category:** BACKUP / PERFORMANCE  
**Check:** Confirm all three VMs have auto-shutdown configured to daily 13:00 UTC

**Command:**
```bash
az resource list \
  --resource-group "rg-ailab-{participant_name}" \
  --resource-type "microsoft.devtestlab/schedules" \
  --query "[].{name:name, resourceName:name | split('shutdown-') | [1], enabled:properties.enabled, time:properties.dailyRecurrence.time}" \
  -o table
```

**Expected Output:**
```
Name                              ResourceName  Enabled  Time
--------------------------------  -----------  ------  ----
shutdown-computevm-vm-app        vm-app        True     1300
shutdown-computevm-vm-db         vm-db        True     1300
shutdown-computevm-vm-win        vm-win       True     1300
```

**FAIL Condition:** Schedule missing, `enabled: False`, or time does not match terraform config (1300 UTC)  
**Tower Note:** Shutdown schedules are **cost controls** in training/lab environments. Disabled schedules = runaway cloud spend. Compute must verify active enforcement; any override requires manager approval.

---

### 15. PERFORMANCE: OS Disk Type & Caching Validation

**Category:** PERFORMANCE  
**Check:** Confirm all OS disks are Standard_LRS with ReadWrite caching

**Command:**
```bash
az vm show \
  --resource-group "rg-ailab-{participant_name}" \
  --name vm-app \
  --query "storageProfile.osDisk.{caching:caching, storageAccountType:managedDisk.storageAccountType, diskSizeGb:diskSizeGb}" \
  -o json

az vm show \
  --resource-group "rg-ailab-{participant_name}" \
  --name vm-db \
  --query "storageProfile.osDisk.{caching:caching, storageAccountType:managedDisk.storageAccountType, diskSizeGb:diskSizeGb}" \
  -o json

az vm show \
  --resource-group "rg-ailab-{participant_name}" \
  --name vm-win \
  --query "storageProfile.osDisk.{caching:caching, storageAccountType:managedDisk.storageAccountType, diskSizeGb:diskSizeGb}" \
  -o json
```

**Expected Output:**
```json
{
  "caching": "ReadWrite",
  "storageAccountType": "Standard_LRS",
  "diskSizeGb": 30  // or 128 for vm-win
}
```

**FAIL Condition:** Caching is `None` or `ReadOnly`, storage type is not `Standard_LRS`, or size mismatch  
**Tower Note:** ReadWrite caching reduces IOPS requirements and improves boot speed. Standard_LRS aligns with lab cost profile. Size mismatches (e.g., 30GB vs 127GB) indicate terraform drift or manual post-deployment changes.

---

### 16. PERFORMANCE: VM Size Sku Validation

**Category:** PERFORMANCE  
**Check:** Confirm VMs provisioned with correct sizes (vm-app & vm-db: B2ms, vm-win: B2s)

**Command:**
```bash
az vm list \
  --resource-group "rg-ailab-{participant_name}" \
  --query "[].{name:name, vmSize:hardwareProfile.vmSize}" \
  -o table
```

**Expected Output:**
```
Name     VmSize
-------  ---------------
vm-app   Standard_B2ms
vm-db    Standard_B2ms
vm-win   Standard_B2s
```

**FAIL Condition:** Any size is `Standard_B1s` or other non-matching tier  
**Tower Note:** B-series VMs provide CPU burstable performance suitable for lab workloads. Downsizing (e.g., B1s) throttles performance; upsizing increases costs. Terraform drift here indicates manual scaling post-deployment and must be justified.

---

### 17. SECURITY: Resource Tags Validation

**Category:** SECURITY  
**Check:** Confirm all resources have required tagging (`owner: training`)

**Command:**
```bash
az resource list \
  --resource-group "rg-ailab-{participant_name}" \
  --query "[].{name:name, tags:tags}" \
  -o json | grep -c '"owner": "training"'

# Or more verbose:
az resource list \
  --resource-group "rg-ailab-{participant_name}" \
  --query "[?!tags.owner].{name:name, tags:tags}" \
  -o table
```

**Expected Output:**
```
(Count of resources with "owner": "training" should equal total resources)
(Or empty table if all resources properly tagged)
```

**FAIL Condition:** Untagged resources appear in output; count mismatch  
**Tower Note:** Tags are **cost allocation anchors** and governance markers. Untagged resources hide true cost-per-project and prevent automated policy enforcement (e.g., cost alerts, compliance audit). Compute must ensure tagging compliance for billing accuracy.

---

### 18. SECURITY: Virtual Network Configuration Review

**Category:** SECURITY  
**Check:** Confirm VNet address space and subnet isolation

**Command:**
```bash
az network vnet list \
  --resource-group "rg-ailab-{participant_name}" \
  --query "[].{name:name, addressSpace:addressSpace.addressPrefixes}" \
  -o json

az network vnet subnet list \
  --resource-group "rg-ailab-{participant_name}" \
  --vnet-name "vnet-ailab" \
  --query "[].{name:name, addressPrefix:addressPrefix}" \
  -o table
```

**Expected Output (VNet):**
```json
[
  {
    "name": "vnet-ailab",
    "addressSpace": ["10.0.0.0/16"]
  }
]
```

**Expected Output (Subnets):**
```
Name                    AddressPrefix
----------------------  ----------------
snet-app                10.0.1.0/24
snet-db                 10.0.2.0/24
AzureBastionSubnet      10.0.3.0/27
```

**FAIL Condition:** VNet uses different CIDR (e.g., 10.1.0.0/16), subnets overlap or missing  
**Tower Note:** Subnet misalignment breaks NSG rules (which reference specific CIDR blocks like 10.0.1.0/24). Compute must validate address space before any hybrid cloud integrations or VPN peering.

---

## ✅ FINAL SIGN-OFF

| # | Check | Status | Validator | Timestamp | Notes |
|---|-------|--------|-----------|-----------|-------|
| 1 | NSG SSH Restriction | ☐ PASS ☐ FAIL | | | |
| 2 | RDP Access Control | ☐ PASS ☐ FAIL | | | |
| 3 | Bastion Host Health | ☐ PASS ☐ FAIL | | | |
| 4 | VM NIC Configuration | ☐ PASS ☐ FAIL | | | |
| 5 | DB Subnet Isolation | ☐ PASS ☐ FAIL | | | |
| 6 | Storage Public Access | ☐ PASS ☐ FAIL | | | |
| 7 | VNet Peering Status | ☐ PASS ☐ FAIL | | | |
| 8 | Boot Diagnostics | ☐ PASS ☐ FAIL | | | |
| 9 | VM Extensions | ☐ PASS ☐ FAIL | | | |
| 10 | Soft-Delete Retention | ☐ PASS ☐ FAIL | | | |
| 11 | VM-to-VM Connectivity | ☐ PASS ☐ FAIL | | | |
| 12 | App-to-DB Path | ☐ PASS ☐ FAIL | | | |
| 13 | SSH Key Acceptance | ☐ PASS ☐ FAIL | | | |
| 14 | Auto-Shutdown Schedules | ☐ PASS ☐ FAIL | | | |
| 15 | OS Disk Configuration | ☐ PASS ☐ FAIL | | | |
| 16 | VM Size Validation | ☐ PASS ☐ FAIL | | | |
| 17 | Resource Tagging | ☐ PASS ☐ FAIL | | | |
| 18 | VNet Configuration | ☐ PASS ☐ FAIL | | | |

---

## 📋 Deployment Readiness Sign-Off

**All Checks Passed:** ☐ YES ☐ NO  

**Failures Identified:** (List any failed checks and remediation steps)

```
_________________________________________________________________

_________________________________________________________________
```

**Compute Engineer Sign-Off:**  
Name: _______________________________  
Date/Time: ___________________________  
Approval: ☐ Environment Ready for Workload Deployment  
          ☐ Environment Requires Remediation (see failures above)

---

## 🔍 Common Failure Scenarios & Quick Remediation

| Failure | Root Cause | Quick Fix |
|---------|-----------|----------|
| SSH connection timeout from Bastion | NSG rule misconfigured or missing | Run `terraform apply` after reviewing nsg-app rules |
| PostgreSQL port 5432 unreachable | NSG allows only 10.0.1.0/24 to vm-db subnet | Verify vm-app is in 10.0.1.0/24; check nsg-db source prefix |
| Boot diagnostics blob not found | Storage account not linked or diagnostics not enabled | Redeploy VMs or manually enable boot diagnostics in portal |
| Auto-shutdown schedule missing | Resource not created by Terraform | Run `terraform apply` to create `azurerm_dev_test_global_vm_shutdown_schedule` resources |
| Bastion ProvisioningState: InProgress | Deployment still in-flight | Wait 5–10 minutes; run checks again; if still stuck, check portal for errors |

---

**Generated:** 2026-06-15  
**Terraform Version:** ~> 3.0 (azurerm provider)  
**Lab Contact:** training@example.com
