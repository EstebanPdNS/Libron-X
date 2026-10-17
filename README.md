<h1 align="center">Libron-X</h1>

<p align="center">
  <strong>Your Bible study library, at home on Mac.</strong><br>
  Compatible with Libronix and classic Logos resources.
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#features">Features</a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="CONTRIBUTING.md">Contribute</a> ·
  <a href="#bug-reports">Bug reports</a>
</p>

<p align="center">
  <a href="https://github.com/EstebanPdNS/Libron-X/releases/tag/v0.2"><img src="docs/images/badges/prerelease.svg" alt="Prerelease: v0.2" height="22"></a>
  <a href="docs/getting-started.md"><img src="docs/images/badges/macos.svg" alt="macOS 14+ · Apple Silicon" height="22"></a>
  <a href="https://github.com/EstebanPdNS/Libron-X/commits/main/"><img src="docs/images/badges/development.svg" alt="Development: active" height="22"></a>
  <a href="LICENSE"><img src="docs/images/badges/license.svg" alt="License: MIT" height="22"></a>
</p>

<p align="center">
  <img src="docs/images/libron-x-v0.1-bibles-map-rounded.png" alt="Libron-X on a MacBook Pro, with two Bibles, a map and the macOS Dock" width="1200">
</p>

<p align="center">
  Bring your books, Bibles, maps and notes together.<br>
  Study passages side by side and pick up where you left off.
</p>

## Features

<table>
  <tr>
    <td width="50%" valign="top"><strong>Read &amp; explore</strong><br>Compare Bibles, navigate passages and explore maps alongside your books.</td>
    <td width="50%" valign="top"><strong>Make room for study</strong><br>Arrange linked readers, save workspaces and restore your study sessions.</td>
  </tr>
  <tr>
    <td width="50%" valign="top"><strong>Find &amp; collect</strong><br>Filter .libron resources by metadata, query local dictionaries and collect notes and highlights.</td>
    <td width="50%" valign="top"><strong>Feel at home on Mac</strong><br>Native controls, copying, printing and export, with ten interface languages.</td>
  </tr>
</table>

## Download

<a href="https://github.com/EstebanPdNS/Libron-X/releases/download/v0.2/Libron-X-v0.2.zip"><img src="docs/images/download-beta.svg" alt="Download macOS beta" width="238" height="46"></a>

**v0.2 is a prerelease in active development.** Requires macOS 14+ and Apple Silicon.

1. Download the ZIP and move **Libron-X.app** to Applications.
2. Follow the [installation guide](docs/getting-started.md) to open the app.
3. Choose your local library and open your first books.

[Release notes](https://github.com/EstebanPdNS/Libron-X/releases/tag/v0.2) · [Installation guide](docs/getting-started.md)

## Documentation

| Start here | Explore further |
| --- | --- |
| [Getting started](docs/getting-started.md) — installation and your library | [Architecture](docs/architecture.md) — how the app fits together |
| [Development](docs/development.md) — build and test | [Source map](docs/source-map.md) — find your way through the code |
| [Contributing](CONTRIBUTING.md) — help improve Libron-X | [Changelog](CHANGELOG.md) — follow each release |

<details>
<summary><strong>Build from source</strong></summary>

Install **Xcode 26+**, with Swift 6.2+ and the macOS 26 SDK, then run:

```sh
git clone https://github.com/EstebanPdNS/Libron-X.git
cd Libron-X/BibliotecaLibre
scripts/test.sh
scripts/build-rebuild-app.sh
open /Applications/Libron-X.app
```

The first build downloads pinned Swift package dependencies. See the [development guide](docs/development.md) for details.

</details>

## Bug reports

[Open an issue](https://github.com/EstebanPdNS/Libron-X/issues/new?template=bug_report.md) with the app version, macOS version, reproduction steps and a screenshot or available logs. Remove private paths and personal content. Do not attach books or license files.

## Contributing

Bug reports, code, documentation and translations are welcome. Read the [contributing guide](CONTRIBUTING.md) or [open an issue](https://github.com/EstebanPdNS/Libron-X/issues) with the app version and steps to reproduce.

---

<p align="center">
  <a href="LICENSE">MIT-licensed code</a> ·
  <a href="BibliotecaLibre/THIRD_PARTY_NOTICES.md">Third-party notices</a> ·
  <a href="docs/images/README.md">Image credits</a><br>
  <sub>Libronix and Logos belong to their respective owners. Libron-X is an independent project.</sub>
</p>
