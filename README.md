# Rust APT Repository

This is an independent, signed APT archive of the newest stable [Rust](https://www.rust-lang.org/) release, plus the retained complete historical releases that fit the archive budget, for Ubuntu 22.04 (Jammy) on `amd64`. It uses Jammy's ordinary package split and file locations: the compiler is `rustc`, Cargo is `cargo`, and supporting tools use their usual names. A normal `apt upgrade` selects the newest available candidate.

This archive is unofficial. It is not operated, sponsored, or endorsed by the Rust Project.

## Packages and layout

Each validated release contains these packages:

| Package           | Purpose                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------- |
| `rustc`           | Compiler, `rustdoc`, and compiler support files                                         |
| `cargo`           | Cargo and shell completions                                                             |
| `libstd-rust-M.m` | Shared Rust runtime and compiler libraries, where `M.m` is the Rust major/minor version |
| `libstd-rust-dev` | Standard-library compilation files                                                      |
| `rustfmt`         | `rustfmt` and `cargo-fmt`                                                               |
| `rust-clippy`     | `clippy-driver` and `cargo-clippy`                                                      |
| `rust-gdb`        | GDB integration                                                                         |
| `rust-lldb`       | LLDB integration                                                                        |
| `rust-doc`        | Rust documentation                                                                      |
| `cargo-doc`       | Cargo documentation                                                                     |
| `rust-src`        | Compiler and standard-library sources                                                   |
| `rust-all`        | Developer-tools metapackage                                                             |

Executables are installed in `/usr/bin`. Rust target libraries and compiler support files live in `/usr/lib/rustlib`; shared libraries use `/usr/lib/x86_64-linux-gnu` and its normal dynamic-loader integration. Sources are installed in `/usr/src/rustc-<full-version>` and linked as `/usr/lib/rustlib/src/rust`. Documentation, manual pages, and completions use their usual system directories.

`rust-all` depends on the compiler, Cargo, formatter, Clippy, and one debugger integration at the same package version. `rust-doc`, `cargo-doc`, and `rust-src` are optional. Compiler-coupled packages always have exactly matching Debian versions; the runtime package keeps its `libstd-rust-M.m` suffix so installed programs can retain the runtime they need during an upgrade.

## Install

The proposed default archive URL is `https://lingyang-kong.github.io/rust`. Use the URL and archive-key fingerprint published by the maintainer for the release you intend to install.

```sh
curl -fsSL 'https://lingyang-kong.github.io/rust/rust-archive-keyring.gpg' \
  | sudo tee /usr/share/keyrings/rust-archive-keyring.gpg >/dev/null

sudo tee /etc/apt/sources.list.d/rust.sources >/dev/null <<'EOF'
Types: deb
URIs: https://lingyang-kong.github.io/rust
Suites: jammy
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/rust-archive-keyring.gpg
EOF

sudo apt update
sudo apt install rustc cargo
```

Install `rust-all` for the developer-tools metapackage. The archive also ships its public key as `rust-archive-keyring.gpg`.

## Versions and APT candidate selection

Packages use conventional Debian versions, `VERSION-REVISION`: for example, an initial Rust 1.98.1 package is `1.98.1-1`. A byte-changing packaging update for that upstream release is `1.98.1-2`. A new upstream release starts again at revision `1`, such as `1.99.0-1`. Published package bytes are never replaced at an existing version.

`packaging/revisions.tsv` stores only explicit upstream-version revisions, one tab-separated row per exception. For example, `1.98.1<TAB>2` records revision 2 for Rust 1.98.1. A version absent from that file has revision 1. The default `RUST_CHANNEL=stable` first discovers the selected upstream version and then performs that lookup, so a later stable release automatically starts at revision 1.

No release has been published yet, so the revision registry has no exceptions. The first published package set starts at revision 1; local development artifacts do not require a revision bump.

`DEB_REVISION` is a positive-integer override for a deliberately selected release only. It is accepted only when `RUST_CHANNEL` is the matching explicit `X.Y.Z` version, never with `RUST_CHANNEL=stable`; this prevents a leftover revision-2 setting from being carried into a newer stable release. When changed bytes for a known upstream release need revision 2, record that version in `packaging/revisions.tsv` and, for an explicit one-off build, use matching values such as `RUST_CHANNEL=1.98.1 DEB_REVISION=2`.

By default this source uses normal APT priorities. Debian version ordering matters: Ubuntu's `1.91.1+dfsg…` version sorts higher than this archive's `1.91.1-1`, so the Ubuntu package remains the candidate when the upstream version is otherwise the same. A newer upstream version such as `1.92.0-1` sorts higher than an older Ubuntu `1.91.1+dfsg…` version when both sources have the ordinary priority of 500.

An operator who intentionally wants this archive selected for packages at the same upstream version may add this optional, package-scoped preference:

```text
Package: rustc cargo libstd-rust-* rustfmt rust-clippy rust-gdb rust-lldb rust-doc cargo-doc rust-src rust-all
Pin: release o=Unofficial Rust APT
Pin-Priority: 600
```

Save it as `/etc/apt/preferences.d/unofficial-rust` and review it whenever Ubuntu advances beyond the desired Rust release. A priority of 600 prefers this archive's candidate over a same-upstream Ubuntu candidate at priority 500; it does not force APT to downgrade an installed `1.91.1+dfsg…` package to `1.91.1-1`. An intentional downgrade requires explicitly choosing the version and allowing downgrades, for example `sudo apt install rustc=1.91.1-1 --allow-downgrades`, together with any compiler-coupled packages that must match it.

## Retained releases

The newest validated twelve-package set is mandatory. Capacity permitting, the archive also retains a newest-to-oldest contiguous prefix of complete historical twelve-package sets. A historical release is either fully present or absent: its `.deb` files remain live in `pool/main/` and its versions remain indexed by the Jammy metadata. The publisher never keeps a partial older release merely to gain space.

`MAX_BYTES` defaults to exactly `1,073,741,824` bytes (1 GiB). GitHub documents the published Pages-site limit as 1 GB, and `actions/deploy-pages@v4` represents that artifact-size threshold as `1073741824` bytes; this archive uses that exact value. [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits) [deploy-pages source](https://github.com/actions/deploy-pages/blob/v4/src/internal/deployment.js)

Retention measures the actual GNU tar artifact that `actions/upload-pages-artifact@v3` creates from `dist`, including the APT metadata and tar overhead, rather than summing package files. [upload-pages-artifact definition](https://github.com/actions/upload-pages-artifact/blob/v3/action.yml) If a completed archive exceeds the budget, it evicts only older complete sets, oldest first. The `deploy-pages` source also contains a separate 10 GB deployment-error message; that is not the Pages selection threshold and is not used for `MAX_BYTES`.

The historical full-set package measurement is 510,263,844 bytes. Two such sets total 1,020,527,688 bytes, leaving 53,214,136 bytes before metadata and tar overhead under the 1 GiB budget. The retained-set count is determined from the final artifact measurement, so this arithmetic does not establish a passing two-release archive.

Old versions remain discoverable, for example with `apt-cache madison rustc`. To install a retained compiler release, request the same Debian version for `rustc` and every compiler-coupled package you choose, including that release's versioned runtime package:

```sh
sudo apt install \
  rustc=1.98.1-2 cargo=1.98.1-2 \
  libstd-rust-1.98=1.98.1-2 libstd-rust-dev=1.98.1-2 \
  rustfmt=1.98.1-2 rust-clippy=1.98.1-2
```

Use the version shown by `apt-cache madison` and include matching versions for any other compiler-coupled packages, such as `rust-gdb`, `rust-lldb`, `rust-doc`, `cargo-doc`, `rust-src`, or `rust-all`.

At the start of a publication run, retention uses the previously published manifest and package pool at the configured HTTPS archive base. It therefore carries forward historical packages even when the GitHub Actions cache is empty. The previous `InRelease` must verify under the archive signing key, and its signed package index must authenticate the catalog's package hashes. Package files are then checksum-verified before they are carried forward; historical versions are not rebuilt. Reuse the signing key across builds that retain history. A legacy package-cache fingerprint is migrated only after a rebuild reproduces the stored package bytes exactly.

The package fingerprint covers `scripts/lib/package.sh`, `scripts/lib/common.sh`, and the Debian maintainer identity. Release inputs and build-tool versions are tracked separately. Polling, release discovery, retention, signing, archive layout, and workflow configuration have a separate publisher fingerprint, so changing them can refresh publication without changing package identities.

## Build and validate the archive

Build on Ubuntu 22.04. The build has a Jammy gate and rejects other host releases, including when a package cache is available. Install the shell tooling and packaging dependencies:

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  bash jq curl gnupg apt-utils dpkg-dev binutils patchelf xz-utils \
  coreutils findutils util-linux shellcheck
```

Run the shell checks and the repository test driver:

```sh
shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh
tests/test.sh
```

For a local signed build, generate a disposable signing key and pass its armored private material only to the build subprocess. This example neither prints nor saves the private key:

```sh
(
  test_gnupg="$(mktemp -d)"
  trap 'rm -rf "$test_gnupg"' EXIT
  chmod 700 "$test_gnupg"
  export GNUPGHOME="$test_gnupg"
  gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'Rust APT local test <local@example.invalid>' ed25519 sign never
  export APT_GPG_PRIVATE_KEY="$(gpg --batch --armor --export-secret-keys)"
  scripts/sync-apt-repo.sh
)
```

The script can query the newest release without building an archive:

```sh
scripts/sync-apt-repo.sh --check-newest-release URL
```

For `RUST_CHANNEL=stable`, the publisher first verifies the signed stable manifest to discover the version, then downloads and verifies that version's canonical manifest, `https://static.rust-lang.org/dist/channel-rust-X.Y.Z.toml`. An explicit `RUST_CHANNEL=X.Y.Z` uses that same canonical manifest, so both paths use the same verified manifest bytes. It verifies component hashes, builds the complete package set, and writes conventional `dists/jammy/main/` metadata and `pool/main/` package storage.

Configuration is supplied through environment variables:

| Variable              | Meaning                                                                                      |
| --------------------- | -------------------------------------------------------------------------------------------- |
| `APT_GPG_PRIVATE_KEY` | Armored private key material used to sign APT release metadata                               |
| `APT_GPG_PASSPHRASE`  | Passphrase for the archive signing key, when it has one                                      |
| `DEB_REVISION`        | Positive revision override; accepted only with an explicit matching `RUST_CHANNEL=X.Y.Z`     |
| `DEB_MAINTAINER`      | Maintainer identity written to Debian metadata                                               |
| `OUT_DIR`             | Location for the generated archive                                                           |
| `CACHE_DIR`           | Location for verified upstream downloads and reusable build data; defaults to `.build/cache` |
| `MAX_BYTES`           | Maximum deployable archive size; defaults to `1073741824` bytes (1 GiB)                      |
| `RUST_CHANNEL`        | `stable` (the default) or a stable `X.Y.Z` release version                                   |

The clean Jammy integration path may install `python3-lldb` only as an external LLDB binding. It is not a build or test-framework dependency of this project.

The current status and exact commands to reproduce validation are in [docs/validation.md](docs/validation.md).

## Local archive activation

The activation helper, `scripts/lib/activation.sh`, publishes a completed archive by atomically replacing `OUT_DIR` with a symbolic link to a generation in a sibling store. For the default output `dist`, the live link points into `.dist.generations/generation-*`. Keep that store beside the output: the live archive depends on it.

Ordinary publication creates and switches to a complete generation without moving the public output path, so there is no normal output gap. A pre-existing real output directory cannot be converted by an ordinary build. During an offline maintenance window, migrate it once with:

```sh
scripts/migrate-archive.sh --offline dist
```

The migration temporarily moves the old directory before installing the link. Resume normal builds only after it completes.

## Publication

The publication workflow is disabled until the repository variable `PUBLICATION_ENABLED` is set to `true`. It polls for a newer release, then builds and validates the complete archive. It runs `tests/test-jammy.sh dist` after the build, and waits for the background ShellCheck and shell tests before saving the cache or uploading the Pages artifact. Dependency installation starts before checkout. Its `contents: read` permission applies by default; only the deployment job receives the Pages and identity-token permissions it needs. Concurrent publications share one non-cancelling `rust-pages` group.

Cached upstream components are verified against their expected hashes. A failed build, validation failure, or archive larger than `MAX_BYTES` leaves the current local archive intact; the completed-generation link changes atomically only after success. Creating or changing a remote publication remains a maintainer action.

## Compliance and support

The repository automation is MIT-licensed; see [LICENSE](LICENSE). Rust and included upstream components have their own licensing terms, summarized in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Signing, key handling, and reporting boundaries are in [SECURITY.md](SECURITY.md).

Report problems with this archive's packaging, signing, or metadata to the archive maintainer. Report Rust language, compiler, Cargo, or upstream security issues through the appropriate Rust Project channels unless the issue is specific to this archive.
