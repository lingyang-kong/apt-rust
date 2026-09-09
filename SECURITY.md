# Security Policy

This repository builds an unofficial signed APT archive of official upstream Rust release components for Jammy/amd64. The archive maintainer controls the APT signing key.

## Scope

- The archive signature attests to this repository's generated APT metadata and Debian packages.
- It does not prove that the Rust Project authored, reviewed, or endorsed this archive.
- The build verifies upstream release data, component hashes, and the independently signed full compiler-source archive with the Rust release key pinned to fingerprint `108F66205EAEB0AAA8DD5E1C85AB96E6FA1BE5FE` in `keys/rust-release.asc`.
- Consumers should verify a new archive-key fingerprint through an independent maintainer-controlled channel before trusting it.

## Reporting

Report a suspected archive-key compromise, incorrect signed metadata, packaging vulnerability, or other archive-specific issue to `lykong@utexas.edu`.

Do not use this address for Rust Project vulnerabilities unless the concern is caused by this packaging pipeline or its published repository metadata. Follow the Rust Project's security reporting process for upstream Rust vulnerabilities.

## Signing key

- Public archive key file: `rust-archive-keyring.gpg`
- Client installation location: `/usr/share/keyrings/rust-archive-keyring.gpg`
- Repository source configuration must use `Signed-By: /usr/share/keyrings/rust-archive-keyring.gpg`.

`APT_GPG_PRIVATE_KEY` accepts armored private key material and `APT_GPG_PASSPHRASE` supplies its passphrase when required. Keep both in a secret store or a short-lived subprocess environment; do not commit, print, or place them in a repository variable visible to untrusted workflows.

The archive signing key is separate from the pinned upstream Rust release key. Do not trust an archive key solely because it appears in an unsigned source checkout or download path.

## Key rotation and revocation

If compromise is suspected, the maintainer must stop publication, publish the replacement fingerprint through an independent channel, and document the affected published releases. The previous public key should remain available long enough for clients to evaluate the transition. A revoked key, its revocation date, and the affected releases must be documented in the repository and publication site.

## Operational integrity

The publisher must validate a release's complete twelve-package set before replacing the live archive. The newest set is mandatory; capacity can retain only a newest-to-oldest prefix of complete historical sets, and an oversized completed archive evicts older whole sets first. Historical package bytes are checksum-verified before carry-forward from the previously published manifest and pool. A failed build, failed validation, or oversized deployment preserves the working local archive.

`scripts/lib/activation.sh` places each complete archive in a sibling generation store and atomically switches `OUT_DIR` to its new generation. For `OUT_DIR=dist`, that store is `.dist.generations`. Normal publication does not move the public output path, so it has no output gap. Retain the store next to `OUT_DIR`. A legacy real output directory requires the explicit `scripts/migrate-archive.sh --offline OUT_DIR` conversion while the archive is offline; that one-time migration can temporarily remove the public path.

The deployment budget defaults to exactly 1,073,741,824 bytes (1 GiB). GitHub says published Pages sites may be no larger than 1 GB, and `actions/deploy-pages@v4` uses that exact byte value for its upload-size warning. The publisher measures the GNU tar artifact produced from `dist` by `actions/upload-pages-artifact@v3`, including repository metadata and tar overhead. The action source's separate 10 GB deployment-error text is not a selected deployment budget. [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits) [deploy-pages source](https://github.com/actions/deploy-pages/blob/v4/src/internal/deployment.js) [upload-pages-artifact definition](https://github.com/actions/upload-pages-artifact/blob/v3/action.yml)

The package fingerprint covers `package.sh`, `common.sh`, and the Debian maintainer identity; release inputs and build-tool versions are recorded separately. Polling, discovery, retention, signing, cache, archive layout, and workflow code have a separate publisher fingerprint. Legacy cache fingerprints migrate only when rebuilt package hashes match exactly. Changed published package bytes require a higher Debian revision: `VERSION-1`, then `VERSION-2`; a new upstream version begins again at revision `1`.

The previous archive's `InRelease` must verify under the archive signing key. Its signed package index authenticates the historical catalog, and each retained file is checked against that index's hash before being re-signed in a new archive. HTTPS access or a hash in an unsigned catalog alone is insufficient. Reuse the archive signing key for builds that carry historical releases forward; key rotation must preserve an explicitly trusted verification path for the older metadata.

The stable manifest is only a signed release-discovery input. The publisher then verifies the versioned canonical manifest, so a stable discovery and an equivalent explicit release use the same verified manifest bytes.
