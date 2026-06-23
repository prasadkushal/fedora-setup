# Workstation-Specific Setup

This directory holds setup that is intentionally tied to one physical
workstation, server, or device.

Keep reusable Fedora setup in the repository root. Put hardware-specific,
direction-specific, or host-specific workflow scripts under:

```text
workstations/<hostname>/
```

Examples:

- `workstations/prime/` - primary workstation notes and host-side setup.
- `workstations/usagi/` - mini-PC client workflow for connecting to `prime`.

Do not put secrets, SSH private keys, auth keys, live passwords, or recovery
material here.
