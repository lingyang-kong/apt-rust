# Rust APT Repository

Independent, signed APT repository for stable [Rust](https://www.rust-lang.org/) releases on **Ubuntu 22.04 (Jammy), amd64**. Installs system-wide tools in `/usr/bin` and supports updates through APT.

Unofficial; not operated, sponsored, or endorsed by the Rust Project.

## Install

The archive has not been published yet. The commands below use the planned URL; confirm availability and the signing-key fingerprint before installing.

```sh
curl -fsSL 'https://lingyang-kong.github.io/apt-rust/rust-archive-keyring.gpg' \
  | sudo tee /usr/share/keyrings/rust-archive-keyring.gpg >/dev/null

echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/rust-archive-keyring.gpg] https://lingyang-kong.github.io/apt-rust jammy main' \
  | sudo tee /etc/apt/sources.list.d/rust.list

curl -fsSL 'https://lingyang-kong.github.io/apt-rust/rust.pref' \
  | sudo tee /etc/apt/preferences.d/rust.pref >/dev/null

sudo apt update
sudo apt install rustc cargo
```

The [preference file](packaging/rust.pref) gives this repository's Rust packages priority 600 over Ubuntu's normal priority 500.

For the compiler, Cargo, formatter, Clippy, and debugger integration together, install `rust-all`. Documentation (`rust-doc`, `cargo-doc`) and sources (`rust-src`) are optional.

## Updates

```sh
sudo apt update
sudo apt upgrade
```

Older releases are retained as space permits. Use `apt-cache madison rustc` to list available versions; compiler-related packages require matching versions.

## Support and license

Report packaging or repository problems to this repository's maintainer. Report upstream Rust issues to the Rust Project.

Automation: [MIT](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for Rust licensing and [SECURITY.md](SECURITY.md) for security reporting. Build and publication instructions are in [the maintainer guide](docs/maintaining.md).
