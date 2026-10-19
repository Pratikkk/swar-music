# Sidebar customization (build 85)

Use the sliders button beside Settings at the bottom of the sidebar, or open
Settings → Sidebar. Changes apply immediately and persist across launches.

**Library Items** lets you show/hide and reorder Home, Recently Added, Artists,
Albums, Songs, Favourites, Listening, Genres and Manage Library. Drag rows, or use
the accessible Up/Down buttons. At least one library shortcut must remain visible.

**Sections** lets you reorder Library, Playlists and Music Folders. Playlists and
Music Folders can be hidden; Library stays available. Search and Settings always
remain visible. This version customizes navigation shortcuts and section placement,
not the order of individual saved playlists or watched folders.

Hiding a shortcut or section does not delete data or stop folder monitoring. Album,
artist and other contextual navigation links can still open hidden destinations.
When the currently selected item is hidden, navigation moves to the first visible
library shortcut. Keyboard navigation follows the visible item/section order.

**Restore Defaults** restores the original order and shows every shortcut and section.
The layout is stored as one local preferences value, independently of library data.
Unknown/duplicate stored identifiers are discarded, new items append automatically,
and damaged/all-hidden settings recover to a usable navigation layout.

Regression tests cover persistence, hidden-item ordering, multiple-item moves,
invalid offsets, unknown/new entries, duplicate identifiers, last-item protection
and corrupt preferences.

Validation: 194 tests across 29 suites passed. The signed universal build passed
bundled-codec verification. Native UI checks covered dragging Songs before Albums,
hiding Genres and Music Folders, moving Playlists above Library with the Up button,
persistence across quitting/reopening, hiding the selected Home shortcut and falling
back to Recently Added, restoring defaults, and opening the Sidebar settings tab.
The default layout and previous Listening screen were restored afterward. Folder
monitoring, the paused playback position and output volume stayed intact.
