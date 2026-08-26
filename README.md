# nutanix-ps-scripts

A collection of PowerShell scripts for operating and managing Nutanix environments.

## Repository structure

<!-- readme-tree start -->
```
.
├── .github
│   ├── actions
│   │   └── readme-tree
│   │       └── action.yml
│   └── workflows
│       └── readme-tree.yml
├── Get-NtnxRecoveryPoints.ps1
├── Get-WindowsNutanixVirtIO.ps1
├── New-NtnxGroupRecoveryPoint.ps1
├── NutanixMove_MultiServerDeployment.ps1
├── NutanixMove_VMPrep.ps1
├── README.md
├── Remove-NtnxRecoveryPoint.ps1
└── tree.bak

5 directories, 10 files
```
<!-- readme-tree end -->

- **RecoveryPoints/** — on-demand recovery point management via the Prism Central v4 API.
- **Move/** — VM migration tooling: VirtIO driver check, Move VM preparation, and multi-server deployment of the prep script.
