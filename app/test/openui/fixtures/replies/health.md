Your homelab is running, but the SMB monitor reports a failure, and Pathfinder was under heavy CPU load when checked.

```openui
root = Card([status, machines, disks, smb, disk, cpu])
status = Status("Homelab", "warning", "3 machines online · 36 of 37 monitors up", "13:27")
machines = Services([a, b, c], "Machines")
a = Service("Pathfinder", "warning", null, "CPU 97% · RAM 61% · AC · 32/32 containers running")
b = Service("NAS-01", "warning", null, "CPU 26% · RAM 54% · AC · 12/12 containers running")
c = Service("Workbench", "success", null, "CPU 0% · RAM 50% · AC · 6/6 containers running")
disks = Gauges([d1, d2, d3])
d1 = Gauge("Pathfinder /", 32, 100, "%", "success")
d2 = Gauge("NAS-01 /srv/data", 36, 100, "%", "warning")
d3 = Gauge("Workbench /", 9, 100, "%", "success")
smb = Callout("warning", "SMB monitor down", "Samba is running and port 445 is reachable from Pathfinder. The monitor failure remains unexplained; share access was not tested.")
disk = Callout("warning", "NAS-01 failing HDD", "170 reallocated sectors and 15 pending. Keep /srv/data for disposable media only.")
cpu = Callout("warning", "Pathfinder CPU spike", "The snapshot showed 97% CPU, with Flutter, Dart, Java and Python processes active. This may be transient.")
```

Backups on all three machines were roughly 10 hours old, and the public portal returned HTTP 200. No changes were made.