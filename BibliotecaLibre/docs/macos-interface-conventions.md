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
