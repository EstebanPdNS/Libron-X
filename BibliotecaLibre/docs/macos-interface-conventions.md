# Modern Apple interface conventions

The user requires a coherent modern Apple interface throughout Libron-X. This
applies to existing surfaces as they are revised and to every new feature.

- Use native macOS controls, SF Symbols and real system Liquid Glass APIs.
  Finder, Pages and Keynote are the interaction and visual references.
- Keep Home, Library and the permanently expanded search on the left, followed
  by the plain Libron-X title without an inline logo. Align all remaining main
  toolbar controls to the right. A search icon alone is insufficient.
- Share one capsule input presentation across references, search, topic queries,
  library filters, document titles, notes and Bible-copy passage fields. Use
  the system's editing, focus ring, selection, undo and input-method behavior.
- Use the shared glass panel-control presentation for dialogs, settings, the
  library, local Find and map controls. Retain intentional link and borderless
  styles for their appropriate roles; do not add glass inside existing glass
  toolbar groups or simulate it with a painted gradient.
- Preserve appropriate Apple form controls, radio groups, checkboxes, segmented
  selection, popup menus, lists and tables. Coherence must not erase the distinct
  semantics or accessibility of different controls.
- Keep content surfaces readable and faithful to their original files. Liquid
  Glass belongs to controls/navigation, not to the typography of source books.
- Preserve all actions, menu commands, shortcuts, focus order, reference formats,
  linked-reader behavior and resource identity during visual changes. Never
  remove a feature to make a toolbar fit; retain its native overflow or menu.
- Check active/inactive states, narrow windows, dialogs, dark/light appearance
  and RTL interface layout. Document the native states actually verified.
- Use availability checks for newer system APIs. On older supported macOS
  versions, keep native controls and functionality rather than shipping a fake
  imitation of Liquid Glass. Current system APIs take precedence over old
  AppKit bezel styles or an independently drawn replacement.

`MacInputPresentation`, `MacPanelControlPresentation`, `MacToolbarPresentation`
and `MacApplicationIdentity` are the shared implementation points. A new feature
must use or extend them instead of introducing another visual language.

Search toolbars use the shared native `MacToolbarSearchField` and its Glass
surface, including dictionary queries: the magnifier and submit action belong
inside the search field, without a detached search button. Keep the search on
the leading side and insert flexible space before trailing action groups.
Dictionary panes retain visible text zoom at every toolbar width; overflow menus
preserve contents, local Find, navigation and the shared reading-output actions.

Reader hyperlinks use the common blue, single-underline presentation in
`ReaderSourceLinkAttributes`, including references inside notes and HTML books.
Style only the actual linked span. Verse commentary and footnote markers must
underline their number or marker, never the complete verse body. Keep source
text, reference offsets, typography and image bytes unchanged.

Clicking a native reader link opens the existing compact preview card directly
and pins it until its X is pressed. Focus loss, source navigation and hover
previews must not dismiss or replace a pinned card. Keep its selectable native
text, images and scrolling. Its Open Here and Open in Another Reading actions
use `MacPanelControlPresentation`; do not replace the compact card with a
separate utility window or require hover before clicking.

Study notes and articles opened in another reading use a dedicated commentary
pane for that Bible edition. Reuse its companion pane, retain native selectable
text and source hyperlinks, and follow the source viewport in one direction.
Keep an explicit native follow/pause control. A missing owned commentary is a
neutral empty state; never substitute the preceding verse's note. Restoring a
workspace preserves the source relationship and pause state.

Illustrated commentary panes use a native split view with selectable text on the
left and large source images on the right, adapting vertically in narrow panes.
Image enlargement uses the shared native image viewer. Suppress only the
publisher's explicitly identified decorative rule and badge files; retain
illustrations, maps, original assets and every source UTF-16 address.

Study tools, collection editors, priority editors, imports, downloads and result reports use `MacToolHeader` for one title hierarchy and the shared native Glass close control. Single-line inputs use the same real Glass capsule as toolbar search. Initial comparison sheets fit their controls; result lists expand only once a report exists. Compact result actions retain tooltips, accessibility labels, keyboard shortcuts and native menus. Dictionary and image-viewer navigation use the reader toolbar control groups. Native settings forms, checkboxes, links and system open/save/print panels retain their appropriate system semantics.

Apply `AppInterfaceLanguage` explicitly at each sheet, popover and AppKit hosting
boundary. A translated label alone does not prove the presented view inherited
the interface direction. Check an actual Arabic or Urdu presentation: headers,
form labels and action groups must follow RTL while source books and physical
workspace coordinates retain their own direction.
