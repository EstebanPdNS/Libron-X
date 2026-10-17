# Managed library and dictionary workflow

Library columns are chosen from the metadata field menu. Sorting, a group scope,
a metadata facet and the text query compose to produce the visible result list.
Language scopes cover every available resource with that language. Read-only
Bible groups are derived separately for each installed Bible language; personal
parallel Bible groups remain editable and appear alongside those language groups.
Automatic group IDs are deterministic and do not modify personal group files.

Reading preferences retain source typography by default, with Times New Roman
as the existing fallback. Selecting a system font family changes reading surfaces
without rewriting resource files. Native rich text retains source font traits;
HTML uses an isolated style override. Changing back to the default removes it.

The dictionary window supports one normalized Unicode word at a time. Phrases,
empty selections and multiline selections clear automatic results. A generation
counter and cancellation prevent a late lookup from replacing a later selection.
Definitions use exact normalized source headwords, not a match somewhere in the
body of an unrelated article. e-Sword term tables, checked Libronix topical indexes
and checked legacy directory entries supply actual destinations.

Right-click lookup opens a small floating panel. Its dictionary selector repeats
the lookup in a different resource. The panel can become a movable/resizable
internal dictionary window, which follows selections in reading windows. Selecting
text in a definition does not recursively trigger the lookup. A missing exact
headword remains an explicit no-definition state.

The existing FeatureHelp service retains native text-editing and feature-specific
menu actions. New import and dictionary topics use the same vector/SF Symbol,
localized help infrastructure and its RTL direction handling. Help content does
not translate or alter original resource text.
