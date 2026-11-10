# Security policy

## Reporting a vulnerability

If you find a security problem in **this port** (the engine build, the
launcher, the packaging, or the build pipeline), please use GitHub's
[private vulnerability reporting](../../security/advisories/new) on this
repository rather than a public issue. Best-effort response — this is an
unofficial community project, not a company.

If you believe **game content** (anything downloaded from BAR's content
network) is malicious, report it to the
[Beyond All Reason project](https://github.com/beyond-all-reason/Beyond-All-Reason)
— they control that content; this project does not host, vet, or modify it.

## What this project ships

Only what is in this repository: the engine binaries built from this source,
the bundled driver stack built from pinned upstream Mesa plus the committed
patches, and the launcher.

There is no published release yet. A build made from this source with
`make app` is ad-hoc signed and runs only on the Mac that built it. When
releases are published they will be on this repository's Releases page and
nowhere else: no other distribution channel is ours.

On each launch the app reads two files from this repository:

- an update feed. An update is installed only if its archive verifies against
  the public key in `packaging/update-public-key`;
- a message file, `message-config/messages.json` on the `main` branch, which
  can show a notice or stop a version from starting.
