<p align="center">
  <img src="https://libron-x.estebanpdn.chatgpt.site/assets/emblem.svg" alt="Libron-X logo, designed by Esteban" width="160">
</p>

<h1 align="center">Libron-X</h1>

<p align="center"><strong>A new open implementation of the Libronix Bible study experience.</strong></p>

<p align="center">
  Reverse engineering in progress · Native macOS development · Independent project
</p>

<p align="center">
  <a href="https://libron-x.estebanpdn.chatgpt.site">Project tracker</a> ·
  <a href="https://github.com/EstebanPdNS/Libron-X/issues">Questions and proposals</a> ·
  <a href="#current-status">Current status</a>
</p>

---

## What is Libron-X?

**Libron-X—with an X—is an independent project intended to become open source, aiming to recreate the functionality of Libronix Digital Library System**, the digital library and Bible study environment developed by Logos.

The goal is to bring that experience back through an original implementation: browsing a library, reading resources, navigating passages, searching, linking texts, and preserving personal study documents. Current development focuses on a native macOS application written in Swift, with a modern interface that feels familiar to users of the original program.

**I am currently reverse engineering Libronix and developing Libron-X from the behavior and structures I can verify.** The work involves understanding its formats, tools, and workflows, documenting their contracts, and rebuilding them with results that can be checked.

This repository introduces the project and its direction. For now, it contains only this README: **source code, executables, and research materials are not published here yet**. A public repository does not mean a downloadable release or a finished implementation is available.

## The original software and its history

Libron-X is the name of this new project. **Libronix Digital Library System**, also known as **Libronix DLS** or **LDLS**, is the original software being studied. The two names refer to different projects.

According to Logos's historical documentation, **Logos Bible Software Series X** launched in **2001**, built on the Libronix DLS architecture. In **2006**, Logos Bible Software 3 expanded that generation of tools. Libronix belongs to the Logos software legacy; it was not created by this project. [Company history published by Logos](https://www.logos.com/media/mediakit/logos_backgrounder.pdf).

The original provided a library of interconnected resources and tools for reading, navigation, searching, and study. Its manual describes libraries, references, windows, and lookup tools. It is one of the historical sources used to understand the experience this project aims to recover. [Original Libronix guide](https://www.logos.com/media/libronix_quick_start_guide.pdf).

### Why revisit discontinued software?

Libronix belongs to a generation of software that no longer receives support. The Logos Help Center lists it among its **unsupported** applications. [Logos support status](https://support.logos.com/hc/es/articles/360007391412-Acerca-de-soporte-gratuito).

In **October 2017**, Logos retired the Libronix web services, including activation, updates, and license synchronization. Its announcement also clarified that the shutdown would not disable existing installations: they could continue running offline with their existing licenses. Describing Libronix as discontinued and without its original online services is therefore more accurate than claiming that every installation stopped working. [Official service discontinuation announcement](https://community.logos.com/discussion/146796/announce-discontinuation-of-libronix-services).

Libron-X grew out of an interest in preserving and rebuilding those study capabilities in a current environment, without relying on continued maintenance of the old application.

## Project goals

The long-term goal is to recreate the functionality and workflows of Libronix for Windows in an original macOS application, working with the library and document types that can be understood and supported through verified implementation.

The work covers these areas:

| Area | Goal |
|---|---|
| Library | Identify resources, inspect metadata, organize collections, and open supported formats. |
| Reading | Display content, indexes, references, links, tables, and graphics with consistent navigation. |
| Bible study | Locate passages, link readers, copy verses, and compare texts. |
| Search | Rebuild queries, options, ranges, and results, from basic searches to specialized tools. |
| Personal documents | Recover notes, lists, favorites, bookmarks, and workspaces while preserving their information. |
| Original languages | Investigate Greek, Hebrew, transliteration, lexicons, morphology, and their relationships with resources. |
| Output | Provide copying, previewing, printing, and exporting with verifiable formats and results. |
| User experience | Offer windows, menus, shortcuts, preferences, and session recovery appropriate for macOS. |

This table describes the **intended scope**. It does not mean every listed feature is finished or available.

## Current status

**Phase: research, reverse engineering, and native prototype development.**

Local implementation and validation are underway. The development documentation reviewed for this introduction on **October 14, 2026** records partial progress in the following areas:

| Area | Documented progress | Current limitation |
|---|---|---|
| Catalog | Importing and identifying resources from a local library. | Recognizing a file does not establish that all of its content can be read. |
| Reader | Reading a verified subset of LSF articles, with indexes, a passage locator, and history. | Complete reading of every format and embedded object remains pending. |
| Navigation | Independent readers, favorites, bookmarks, and reference links in verified cases. | All variations and original workflows still need validation. |
| Documents | Rich-text notes, reference lists, and import of selected XML document types. | Anchors, links, and properties have partial support. |
| Workspaces | An original format for saving and restoring part of the application state. | Equivalence with all original session behavior has not been established. |
| Search | Local word and phrase queries, operators, and results within supported scopes. | Original indexes, specialized search, and general parity remain in development. |
| Reader output | Previewing and exporting supported text to HTML, TXT, PDF, and RTF, with printing integration. | Complete tables, graphics, typography, and pagination require further work. |
| Copy Bible Verses | Passage selection, styles, previewing, and clipboard output in verified cases. | Acceptance testing continues for styles, references, languages, and destination applications. |

These advances are recorded in local development documentation and evidence; **they do not constitute independent certification of every feature**. They also do not imply that a public release or an application ready for general use is available.

Full functional equivalence with Libronix remains an open goal. Study guides, advanced tools, add-in families, and comprehensive resource compatibility require additional research, implementation, and testing.

### Development platform

The current prototype is being developed in **Swift for macOS**. The local configuration specifies macOS 14 or later and Swift 6. Verified work is concentrated on the Apple Silicon development Mac; compatibility across all declared operating system versions and architectures has not been certified.

The original Windows application serves as a behavioral reference. No Windows, Linux, or mobile version of Libron-X is currently announced.

## Reverse engineering approach

The work combines observation of the original application, format analysis, and development of an original implementation:

1. **Inventory behavior:** identify tools, menus, inputs, options, outputs, and documents.
2. **Observe real workflows:** check what the original does, how it handles errors, and what it preserves after closing and reopening.
3. **Analyze structures:** study indexes, references, styles, and formats while preserving the original files.
4. **Define contracts:** distinguish established facts, verified behavior, and unresolved hypotheses.
5. **Implement and compare:** develop original components and compare their results with reference cases.
6. **Validate preservation and recovery:** check persistence, cancellation, integrity, and document recovery.

A feature is not considered equivalent simply because its button exists, one example opens, or an isolated test passes. Acceptance requires comparing inputs, results, navigation, errors, and persistence within an explicit scope.

## Next steps

- Complete acceptance testing for Copy Bible Verses, its styles, and paste destinations.
- Expand resource reading and presentation, including tables, graphics, and typography.
- Rebuild references, indexes, and searches with results comparable to the original.
- Complete personal documents, study tools, and session restoration.
- Improve accessibility, performance, and window and control behavior.
- Prepare publication of the original source code, with attribution, documentation, and reproducible tests.
- Verify installation, compatibility, and distribution before offering a public release.

The plan will expand as research reveals previously unidentified features or options. No release date has been committed.

## Progress and participation

The [Libron-X project tracker](https://libron-x.estebanpdn.chatgpt.site) brings together the plan and task status. Its checkboxes represent individual deliverables: **the percentage of completed tasks does not measure functional equivalence with the original**.

Use this repository's [issues](https://github.com/EstebanPdNS/Libron-X/issues) to propose features, describe Libronix workflows you remember, or share links to public documentation. Reports are especially useful when they identify the tool, steps, options, and expected result.

Until the source code is published, public build instructions and a code contribution workflow are not available. The repository will expand when that stage is ready.

## Open source, libraries, and rights

The intention is to publish **the original Libron-X implementation as open-source software**. The local original-code package already declares the MIT license; publication of that package and its corresponding notices will be prepared for the source release. This README does not publish that package or grant rights to third-party materials.

The project keeps original code, research materials, and reference resources separate. This repository does not include commercial books, private libraries, installers, original executables, license files, or unlocking materials. Intended compatibility concerns resources users have the right to use; it is not a promise of access to every library.

Discontinuing software does not place its books, code, fonts, or trademarks in the public domain. The rights of Logos and the respective publishers and authors remain separate from those of Libron-X.

## Identity and credits

**Project and logo design: Esteban.**

The project is named **Libron-X**. The emblem at the top is the approved project design, loaded from its public website to keep this repository limited to the README. The logo has its own attribution and terms; it is not declared MIT-licensed by association with the future source release.

Libronix Digital Library System and Logos are mentioned to identify the software being studied and its history. **Libron-X is an independent project, with no affiliation, sponsorship, or endorsement from Logos.** The original application's trademarks and materials belong to their respective owners.

## Historical sources

- [Logos Bible Software: Company Background](https://www.logos.com/media/mediakit/logos_backgrounder.pdf): the relationship between Logos Bible Software Series X, Libronix DLS, and Logos 3.
- [Libronix Quick Start Guide](https://www.logos.com/media/libronix_quick_start_guide.pdf): documentation of the original experience and tools.
- [ANNOUNCE: Discontinuation of Libronix Services](https://community.logos.com/discussion/146796/announce-discontinuation-of-libronix-services): service retirement and continued offline use of existing installations.
- [Logos Help Center: About Free Support](https://support.logos.com/hc/es/articles/360007391412-Acerca-de-soporte-gratuito): classification of Libronix DLS as unsupported software. The linked source is in Spanish.

---

<p align="center"><strong>Libron-X · Preserve a study experience, understand it, and rebuild it with original code.</strong></p>
