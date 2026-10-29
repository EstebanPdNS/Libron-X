# Bible-copy templates and output

The shipping MacRebuild copy tool selects all six stable built-in presets and
user-created templates. Built-ins are read-only. Duplicate creates a separate
editable style with a new identity; saving activates it, while Use Template can
activate an unchanged built-in or custom style. Custom names are user content;
built-in names are interface strings translated in all ten languages.

## Editing and persistence

The template editor separates text patterns, formatting and language policies.
Each of the four patterns has independent bold, italic, underline, superscript
and subscript controls; the last two are mutually exclusive in the editor.
Formatting includes source character/paragraph formatting, red-letter text,
Bible-text-only, citation, footnotes and paragraph policy. Full-source text uses
source paragraphs. Greek/Hebrew Unicode, transliteration and supported Hebrew
mark policies use the existing formatter. An inherited unsupported Hebrew font
encoding remains identified and is not offered as a working conversion.

Custom styles and the selected style are independently persisted through the
existing validated personal-state writer. An edit retains the loaded original
for the optimistic save check. Unsaved changes require save/discard/cancel before
closing or changing selection; the application termination guard is retained.
Template provenance and immutable source XML remain independent of owned edits.

Loading a style initializes the copy controls from its saved policies. One-off
changes to paragraphs, citation or footnotes affect the prepared request without
rewriting the template. Reference language is independently persisted. Changes
to passage, resource, style, language or options invalidate the prepared result.
Formatting runs off the interface actor, and cancelled work cannot publish an old
payload after an input change.

## One prepared result

One NativeBibleCopyPayload supplies the attributed preview, plain text, RTF and
HTML. Copy writes all three representations. TXT, RTF and HTML exports write the
same bytes from the captured payload, including when a system save panel is
open. The main preview uses a selectable native NSTextView so paragraph writing
direction and rich attributes use the same layout engine as native paste targets.
AppKit adapts source colors to dark appearance; output colors are unchanged.

General Mac RTF includes visible endnotes to preserve footnotes in destinations
whose RTF readers drop structural footnote destinations. Structural RTF is kept
separately in the native payload for compatible consumers. HTML escapes source
text before adding formatter markup and denies external content loading.

The current extraction service still accepts checked LSF sources. Other native
Bible formats remain the separate F186 requirement; this interface work does not
claim their extraction is complete. Source boundaries, unavailable verses,
unsupported content, cancellation and source-file changes retain the existing
read-only service checks.
