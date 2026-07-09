# 15 — Dynamic VMs & Graphical Remote Control

Three layers, from "already there" to "polished portal". Combined with
WireGuard (docs/09), all of it works identically from anywhere on earth.

## Layer 1: Proxmox itself (already deployed — don't overlook it)

The Proxmox web UI **is** a dynamic VM platform with graphical access:

- **Create/destroy VMs on demand**: web UI → *Create VM*, or clone in
  seconds once you keep a template (right-click VM → *Convert to
  template*, then *Clone*). API/CLI for scripting (`qm`, or the
  [REST API](https://pve.proxmox.com/pve-docs/api-viewer/) —
  Terraform/Ansible providers exist).
- **Graphical console in the browser**: every VM's *Console* button is
  [noVNC](https://novnc.com) (MPL-2.0) — full graphical access
  including BIOS, installers, and desktops, no client software, works
  through `http://proxmox.home.lan` and over WireGuard.
- **SPICE** for a richer console (clipboard, audio, auto-resize): set
  the VM's *Display* to SPICE and open it with
  [virt-viewer](https://virt-manager.org) (GPL-2.0) from any OS.

If the need is "occasionally poke a VM graphically", stop here — it's
already solved.

## Layer 2: desktop VM factory (`scripts/30-create-desktop-vm.sh`)

One command stamps out a ready-to-use Linux desktop:

```bash
bash scripts/30-create-desktop-vm.sh testbox            # 2c/4GB/40G defaults
bash scripts/30-create-desktop-vm.sh workbench 8192 4 60
```

Each run: auto-picks the next free VMID, clones the Debian 13 cloud
image onto Ceph, and cloud-init installs **XFCE + xrdp** on first boot
(~10 minutes; watch via the noVNC console). The script prints the
generated login and the one-liner to fetch its DHCP address. Connect
with any RDP client — Remmina (Linux), the built-in Windows client,
Microsoft Remote Desktop (macOS/iOS/Android) — at `<ip>:3389`.

Disposable by design: `qm stop <id> && qm destroy <id> --purge`. Tagged
`desktop` in the UI so they're easy to spot. Not HA-enrolled — these
are pets/labs, not services (add `ha-manager add vm:<id>` if one grows
up). Windows desktops work the same way once you make one VM from a
Windows ISO and template it (RDP is built into Windows Pro).

## Layer 3: Guacamole — the browser desktop portal

[Apache Guacamole](https://guacamole.apache.org) (Apache-2.0) runs on
cloud-data and turns any browser into an RDP/VNC/SSH client — no
software on the connecting device at all. `http://desktop.home.lan`
from a tablet in a hotel (over WireGuard) → full desktop, with
clipboard sync, file transfer, and per-user connection lists.

Setup (once, after cloud-data's compose is up):

```bash
# on cloud-data:
sudo bash init-guacamole.sh     # loads the DB schema
```

Then at `http://desktop.home.lan`:

1. Login `guacadmin` / `guacadmin` → **change it immediately**
   (*Settings → Preferences*), ideally create your own admin user and
   delete guacadmin.
2. *Settings → Connections → New connection*: protocol **RDP**,
   hostname = the desktop VM's IP, port 3389, the username/password the
   factory printed, and enable "Ignore server certificate".
3. Optional niceties per connection: *display → resize method:
   display-update*, *device redirection → enable drive* (file
   transfer via browser).

Guacamole can also front **SSH** sessions (terminal in browser) and
**VNC**. One portal, every machine.

## How the pieces compose

| Want | Use |
|------|-----|
| Poke at any VM, incl. during OS install | Proxmox noVNC console |
| A disposable Linux desktop in 10 min | factory script → RDP |
| Desktops from a browser/tablet, anywhere | Guacamole (+ WireGuard) |
| Scripted fleet of VMs | `qm`/API — the factory script is the template to copy |
