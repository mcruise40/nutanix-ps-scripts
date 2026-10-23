# nutanix-ps-scripts

A collection of PowerShell scripts for operating and managing Nutanix environments.

## Repository structure

<!-- readme-tree start -->
```
.
├── .github
│   └── workflows
│       └── readme-tree.yml
├── Move
│   ├── Get-WindowsNutanixVirtIO.ps1
│   ├── NutanixMove_MultiServerDeployment.ps1
│   ├── NutanixMove_VMPrep.ps1
│   └── README.md
├── README.md
└── RecoveryPoints
    ├── Get-NtnxRecoveryPoints.ps1
    ├── Invoke-NtnxRecoveryPointCleanup.ps1
    ├── New-NtnxGroupRecoveryPoint.ps1
    ├── README.md
    └── Remove-NtnxRecoveryPoint.ps1

4 directories, 11 files
```
<!-- readme-tree end -->

- **RecoveryPoints/** — on-demand recovery point management via the Prism Central v4 API, and a guided cleanup of expired or orphaned recovery points.
- **Move/** — VM migration tooling: VirtIO driver check, Move VM preparation, and multi-server deployment of the prep script.
- **Performance/** — performance metrics via the Prism Central v4 API (CPU Ready Time per VM, CPU peak per cluster/host with N-1 projection).
- **Upgrade/** — pre-upgrade readiness check via the Prism Central v4 API (resources with N-1, NCC, alerts with justification, HTML report for the change).
