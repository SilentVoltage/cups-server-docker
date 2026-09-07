# plugins.d

Drop vendor driver packages here for **air-gapped or offline builds**. The
`drivers` stage copies this directory in and `apt-get install`s every `.deb` it
finds, alongside anything fetched via `CUPS_DRIVER_DEB_URLS`.

```
plugins.d/
├── .gitignore          keeps *.deb out of git by default
├── README.md           this file - also what keeps the directory tracked
└── cnijfilter2_6.20-1_amd64.deb    (example, not committed)
```

Accepted here: `.deb` only. Runtime plugin loading (`.ppd`, `.sh` hooks) is a
separate mechanism — that reads `$CUPS_PLUGIN_DIR` inside the running container,
not this build-time directory.

## Why .deb files are gitignored

Vendor driver blobs (Canon `cnijfilter2`, Epson, Brother) ship under EULAs that
generally prohibit redistribution. Committing one to a public repository is a
licence violation, and it lands in every clone forever.

For a **private** repo where you have accepted the vendor terms, force-add:

```sh
git add -f plugins.d/cnijfilter2_6.20-1_amd64.deb
```

For anything published, prefer:

- `CUPS_DRIVER_DEB_URLS` + `CUPS_DRIVER_DEB_SHA256SUMS` at build time, or
- the chart's `plugins.debs` at deploy time, so each operator fetches the blob
  under their own acceptance of the vendor licence.

## Verify before adding

```sh
sha256sum plugins.d/*.deb
dpkg-deb -I plugins.d/foo.deb            # metadata, dependencies
dpkg-deb -c plugins.d/foo.deb            # file list - check for setuid, /etc writes
```

Note most vendor filters are amd64-only; a multi-arch build with one of these
present will fail on the arm64 leg. Build those tags single-arch.
