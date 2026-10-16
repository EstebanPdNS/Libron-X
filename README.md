<p align="center">
  <img src="docs/images/libron-x-v0.1-bibles-map.png" alt="Libron-X on a MacBook Pro, with two Bibles, a map and the macOS Dock" width="1200">
</p>

A native macOS Bible study workspace, compatible with Libronix and classic Logos resources.

**v0.1 beta prerelease · Active development · Apple Silicon · macOS 14+**

Bring your books, Bibles, maps and notes together. Study passages side by side, link readers and save your workspace for the next session.

## Try the beta

Download **Libron-X-v0.1.zip** from [Releases](https://github.com/EstebanPdNS/Libron-X/releases/tag/v0.1), extract it and move **Libron-X.app** to Applications. Follow the [installation guide](docs/getting-started.md) to get started with your own local library.

## Study workspace

- Read Bibles side by side, explore maps and navigate passages.
- Search your library and organize notes, verse lists and favorites.
- Arrange linked readers and save your study sessions.
- Copy, print and export your work with native macOS controls.
- Choose from ten interface languages, including English, Spanish and Portuguese.

## Build

Install Xcode 26 or later (Swift 6.2+ and macOS 26 SDK or later), then run:

```sh
git clone https://github.com/EstebanPdNS/Libron-X.git
cd Libron-X/BibliotecaLibre
scripts/test.sh
scripts/build-rebuild-app.sh
open dist/Libron-X.app
```

The first build downloads pinned Swift package dependencies. [Development guide](docs/development.md).

## Project guide

| Location | Contents |
| --- | --- |
| [BibliotecaLibre/Sources](BibliotecaLibre/Sources) | Current Mac workspace, portable engine, native output and CLI |
| [BibliotecaLibre/Tests](BibliotecaLibre/Tests) | Synthetic regression tests and optional local-corpus checks |
| [docs](docs/README.md) | Setup, architecture, source map and resource formats |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

Report reproducible problems in [Issues](https://github.com/EstebanPdNS/Libron-X/issues). Include the app version, macOS version, steps and a screenshot when useful. Keep books, licenses and personal study files private.

MIT-licensed project code. [Third-party notices](BibliotecaLibre/THIRD_PARTY_NOTICES.md). Libronix and Logos belong to their respective owners; this project is not affiliated with or endorsed by Logos.
