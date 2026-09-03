# Compact Panel, Checklists, Favorites — Design

Date: 2026-09-03
Branch: `feature/compact-panel-checklists-favorites`

## Goals

1. The panel no longer has to span the full screen height. It can be resized vertically and stays bottom-anchored.
2. A small always-on-top floating button in the bottom corner toggles the panel, in the style of OpenWhispr's pill.
3. Edge activation (mouse-to-screen-edge reveal) is off by default.
4. A dedicated **Checklist** note type: a native list of check items, each with its own detail page holding notes and links.
5. A **Favorites** section of web links, hidden behind a star button in the panel header.
6. Targeted glass-UI polish: hairline highlights, translucent cards, consistent hover treatment.

## Non-goals

- No changes to task-list rendering inside regular markdown notes.
- Favorites hold URLs only, not notes.
- The favorites section's open/closed state is not persisted; it starts closed on every launch.
- No sync, no cloud, no new external dependencies.

---

## 1. Panel height

### Settings

`ShortcutSettings` gains:

- `panelHeight: CGFloat?` persisted under `panelHeight` (Double). `nil` means "full height" and is the default.
- `floatingButtonEnabled: Bool` persisted under `floatingButtonEnabled`, default `true`.
- `edgeActivationEnabled` default changes from `true` to `false`. No migration; users who already wrote the key keep their value.

### Frame math

`SidePanelController.panelFrames(visibleFrame:side:)` becomes the single source of truth for the panel rect:

```
bottomInset = floatingButtonEnabled ? FloatingButtonController.reservedHeight : 0
height      = min(panelHeight ?? visibleFrame.height, visibleFrame.height) - bottomInset
y           = visibleFrame.minY + bottomInset
```

Width logic is unchanged. `parkedFrame` uses the same height. `ResizeHandleView.minWidth` stays 400; a new `minHeight` of 320 applies to vertical resize.

### Vertical resize handle

A second handle strip runs along the panel's **top** edge (8pt tall, centered on the visible card border 8pt from the window top, matching `PageLayout`'s top padding). Dragging it moves the top edge; the bottom stays anchored. On drag end the height is written to `panelHeight`. If the user drags to within 8pt of the screen top, the value snaps to `nil` (full height) so the panel returns to the classic look.

The existing width handle is unchanged.

### Settings UI

In `BehaviorSettingsTab`, a new "Panel Size" section:

- Toggle **Full height** (bound to `panelHeight == nil`). Turning it on clears `panelHeight`. Turning it off sets `panelHeight` to 60% of the main screen's visible height.
- Toggle **Show floating button**.

Both post `.shortcutSettingsChanged` so the controller re-lays out live.

---

## 2. Floating button

### `FloatingButtonController` (new, `Core/Window/`)

Owns one borderless `NSPanel`:

- Size 44×44 content in a 60×60 window so the shadow and hover halo aren't clipped.
- `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `ignoresMouseEvents = false`, non-activating (`.nonactivatingPanel` style) so clicking it never steals focus from the frontmost app.
- Positioned 8pt from the bottom and 8pt from the side matching `edgeSide` (right → bottom-right, left → bottom-left) of the screen where the panel lives. Re-positions on `NSApplication.didChangeScreenParametersNotification` and `.shortcutSettingsChanged`.
- `reservedHeight` static = 60 (window height) so the panel can sit above it.

Content is a SwiftUI `FloatingButtonView`:

- A circle using `VisualEffectView` with the current panel tint/material, a 1px hairline ring, and an SF Symbol (`sidebar.right` / `sidebar.left` mirrored by edge; fills when the panel is shown).
- Hover: scale 1.06, ring brightens. Press: scale 0.94.
- Click calls `SidePanelController.togglePanel()`.

The button is created and shown in `AppDelegate.applicationDidFinishLaunching` after the panel controller exists, and hidden/shown when `floatingButtonEnabled` changes.

### Interaction with the panel

- The panel's click-outside monitor is a global monitor and does not fire for clicks in our own windows, so a click on the button reaches `togglePanel` cleanly.
- `SidePanelController.isMouseInPanel()` also returns true when the cursor is over the floating button window, so hovering the button does not start the auto-hide timer.

---

## 3. Checklist note type

### Data model

`Note` gains `kind: NoteKind` where:

```swift
enum NoteKind: String, Codable { case note, checklist }
```

Persisted in the sidecar: `SidecarStore.NoteEntry.kind: String?` (absent = `note`). Trash entries carry the same field so a restored checklist stays a checklist.

Checklist content is plain markdown in the `.md` file:

```markdown
# Groceries

- [ ] Milk
- [x] Eggs
  Get the free-range ones.
  - [Costco](https://www.costco.com)
- [ ] Call the plumber
  - [Yelp listing](https://yelp.com/biz/...)
```

### Groups

Items can be organized into named groups. A group is a `## Heading` line inside the checklist file; every item after it belongs to that group until the next `##`. Items before the first `##` are ungrouped and render at the top with no header. Example:

```markdown
# Classes

## PHYS410 (Classical Mechanics)
- [ ] Problem set 3
- [x] Read ch. 5

## PHYS467 (Quantum)
- [ ] Lab report

## ENEE304 (Nanoelectronics)

## ENEE382 (Electromagnetism)
```

```swift
struct ChecklistGroup: Identifiable, Equatable {
    var id: UUID       // in-memory only
    var name: String
    var items: [ChecklistItem]
}
```

`ChecklistDocument` holds `ungrouped: [ChecklistItem]` plus `groups: [ChecklistGroup]`. Empty groups are preserved (a `##` line with no items) so a freshly seeded class list keeps all four headers.

UI: each group renders as a section with a bold header row, its own item list, and its own "Add item" field. Completed items sink to the bottom of their own group rather than to a single global "Completed" list. The group header has a right-click menu: Rename, Move Up, Move Down, Delete group (asks to confirm when the group has items; items are deleted with it). A "+ Group" button at the bottom of the screen adds a new group with an inline name field. Items can be dragged between groups.

Seeding: on the first launch where no checklist notes exist (checked via the sidecar `kind` field after load), the app creates one checklist titled **Classes** at the root with these four empty groups in this order:

- PHYS410 (Classical Mechanics)
- PHYS467 (Quantum)
- ENEE304 (Nanoelectronics)
- ENEE382 (Electromagnetism)

A `didSeedDefaultChecklist` UserDefaults flag prevents re-seeding after the user deletes it. New checklists created by the user start with no groups.

Parsing rules (`ChecklistDocument`, new in `Core/Checklist/`):

- Line 1 `# Title` is the heading, handled exactly as regular notes do (title derives from it).
- A `## Name` line starts a new group. Everything after it until the next `##` belongs to that group.
- A top-level `- [ ] ` or `- [x] ` line starts an item. `[X]` counts as checked.
- Subsequent lines indented by two or more spaces belong to that item:
  - `- [label](url)` → a link with that label and URL.
  - A bare URL line → a link whose label is the host.
  - Anything else → appended to the item's notes, joined with newlines, leading indent stripped.
- Blank lines between items are ignored. Non-matching top-level lines are preserved verbatim in a `preamble` / `trailing` bucket so external edits aren't destroyed, but the UI does not display them.
- `serialize()` writes back in the canonical form above. Round-trip of a canonical document is byte-identical.

`ChecklistItem`:

```swift
struct ChecklistItem: Identifiable, Equatable {
    var id: UUID          // stable in memory only; not persisted
    var title: String
    var isDone: Bool
    var notes: String
    var links: [ChecklistLink]
}
struct ChecklistLink: Identifiable, Equatable { var id: UUID; var label: String; var url: URL }
```

### Store integration

- `NoteStore.createChecklist(in:)` mirrors `createNote` with `kind = .checklist` and initial content `"# Title\n\n"`.
- `NoteStore.updateContent` already handles title extraction and dirty tracking; the checklist screen calls it with `ChecklistDocument.serialize()` output. No new save path.
- `FileStorage.upsertSidecarEntry` writes `kind`. `loadAllNotes` reads it.
- `Note.previewText` returns `"3 of 7 done"` for checklists (localized). `NoteCardView` shows a compact progress badge (`checkmark.circle` + `3/7`) instead of the text preview.
- Search, tags, move, rename, trash, restore, peek: unchanged. Peek renders the markdown as-is.

### Screens

`ContentView` chooses `ChecklistScreen` instead of `EditorScreen` when `selectedNote?.kind == .checklist`. Header layout (back, title, path, pin, copy, delete, dates) is shared by extracting today's editor header into `NoteHeaderView`.

**`ChecklistScreen`** (`UI/Checklist/`):

- `List` of open items, then a collapsible "Completed" group.
- Row: `CheckMarkerView` (24pt circle, glass material, hairline ring; checked = accent fill with white check, spring animation) + title. Done rows are strikethrough and 55% opacity.
- Clicking the marker toggles `isDone`. Clicking the title opens `ChecklistItemDetailView` for that item (push transition, same `navigationDirection` mechanism).
- Drag to reorder within the open group via `onMove`.
- Right-click: Rename, Delete. Delete key deletes the selected row.
- Bottom "Add item" text field; Return commits and keeps focus for rapid entry.
- Header adds a "Clear completed" icon button (`trash.slash`), disabled when none are done.
- Progress line under the header: thin capsule bar + "3 of 7".

**`ChecklistItemDetailView`**:

- Back button returns to the list.
- Editable title (plain `TextField`, headline font).
- Notes: a multi-line `TextEditor` styled like the panel (transparent background). Plain text, not the markdown engine, to keep scope contained.
- Links: list rows with `link` icon, label, and host. Click opens in the default browser via `NSWorkspace.shared.open`. Right-click: Copy link, Edit label, Delete. "+" reveals an inline URL field; on commit the label defaults to the host and can be edited afterwards. If the pasteboard holds a URL when "+" is pressed, the field is pre-filled.
- Every edit updates the in-memory `ChecklistDocument` and pushes `serialize()` through `noteStore.updateContent`, so the existing 1s debounce and dirty-save apply.

### Creating checklists

`HomeFolderView` and `NoteListView` headers gain a `checklist` icon button (`checklist`) before the new-note button. The right-click "New" menu (where present) gains "New Checklist". Local shortcut: none in this iteration.

### Localization

New keys in `en.json`; other locales fall back to English via `L10n`'s existing missing-key behavior (verify: if `L10n` returns the key string instead, copy the English values into the other three files).

---

## 4. Favorites

### Data

`FavoritesStore` (`Core/Storage/FavoritesStore.swift`, `@Observable`, singleton like `SidecarStore`):

```swift
struct Favorite: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var url: URL
    var createdAt: Date
}
```

Persisted as `.edgemark/favorites.json` (`{ "version": 1, "items": [...] }`), ISO-8601 dates, written atomically on every mutation. Loaded once at launch after the sidecar. Path follows the resolved storage directory, so changing the notes folder moves favorites with it (the existing migration copies the whole `.edgemark` folder).

### UI

- `HomeFolderView` header: a `star` `HeaderIconButton` placed left of `PinButton`. Filled star when open. Toggles `@State showFavorites`. The state lives in `NoteStore` (`showFavorites`) so it survives navigation into folders and back but resets on launch.
- When open, `FavoritesSectionView` appears at the top of the Home content, above the folders grid, with the same card styling. Slide-and-fade transition.
- Section header: "Favorites" label, count, and a `plus` button. Body: rows (`link` icon, title, host in secondary). Empty state text when there are none.
- Add flow: `plus` shows an inline `TextField` for the URL. Pre-filled from the pasteboard when it contains a URL. Return commits: URL is normalized (adds `https://` if there's no scheme), title defaults to the host without `www.`. Escape cancels.
- Row click opens the URL in the browser. Right-click: Edit title (inline rename using the existing `InlineRenameEditor` pattern), Copy Link, Delete.
- Drag to reorder via `onMove`.

---

## 5. Glass polish

Scoped to these files; no global restyle:

- `PageLayout`: corner radius 10 → 12; add a `.overlay(RoundedRectangle.stroke(hairline))` where hairline is white at 0.14 in dark and 0.55 in light appearance, 1px. A new `GlassCard` view modifier encapsulates material + tint + radius + hairline so `PageLayout`, `NoteCardView`, `FavoritesSectionView`, `CheckMarkerView`, and the floating button all use it.
- `NoteCardView`: `.quinary` fill → `.ultraThinMaterial` at reduced opacity plus hairline; on hover, background brightens slightly and the card lifts 1pt with a 0.15s ease. Radius 6 → 8.
- `HeaderIconButton`: unchanged behavior; radius 6 → 7 to match.
- Floating button and check marker use `GlassCard` in circular form.

Opaque panel style (`AppSettings.panelStyle == .opaque`) keeps the hairline but uses the opaque material, as today.

---

## Testing

There is no test target in the project. Add `EdgeMarkTests` (XCTest, macOS) with:

- `ChecklistDocumentTests`: parse → serialize round-trip on the canonical example; parsing of `[X]`, bare URLs, multi-line notes, preamble preservation; groups with and without items, empty groups preserved, ungrouped items before the first `##`; toggling, reordering, and moving an item between groups produce expected markdown.
- `FavoritesStoreTests`: load/save round-trip in a temp directory; URL normalization; host-derived titles.
- `PanelFrameTests`: `panelFrames` for full height, custom height, with and without the floating button inset, both edges.

Manual verification checklist:

- Drag panel top edge; relaunch; height persists. Full-height toggle restores classic layout.
- Floating button appears bottom-right, switches corner when edge side changes, survives Space switch and a fullscreen app, and toggles the panel without stealing focus from the previous app.
- Edge activation is off on a fresh install; turning it on in Settings still works.
- Fresh install seeds the Classes checklist with the four groups. Delete it, relaunch, confirm it is not re-created.
- Create a checklist, add items, check some, open one, add notes and two links, add a group and drag an item into it, relaunch, verify the `.md` on disk matches the canonical format and everything reloads.
- Open the same `.md` in another editor, add an item, reopen the panel, verify the external-change flow still works.
- Favorites: add from clipboard, add by typing a bare domain, rename, reorder, delete, relaunch, verify `favorites.json`.
- Light and dark appearance, translucent and opaque panel styles.

## Files touched (expected)

New:
- `Core/Window/FloatingButtonController.swift`, `UI/Components/FloatingButtonView.swift`
- `Core/Checklist/ChecklistDocument.swift`
- `Core/Storage/FavoritesStore.swift`
- `UI/Checklist/ChecklistScreen.swift`, `UI/Checklist/ChecklistItemDetailView.swift`, `UI/Checklist/CheckMarkerView.swift`
- `UI/Components/FavoritesSectionView.swift`, `UI/Components/GlassCard.swift`, `UI/Components/NoteHeaderView.swift`
- `EdgeMarkTests/…`

Modified:
- `Core/Shortcuts/ShortcutSettings.swift`, `Core/Window/SidePanelController.swift`, `App/AppDelegate.swift`, `App/ContentView.swift`
- `Core/Storage/Note.swift`, `NoteStore.swift`, `FileStorage.swift`, `SidecarStore.swift`
- `UI/EditorScreen.swift`, `UI/Navigation/HomeFolderView.swift`, `UI/Navigation/NoteListView.swift`
- `UI/Components/PageLayout.swift`, `NoteCardView.swift`, `HeaderIconButton.swift`
- `UI/Settings/BehaviorSettingsTab.swift`, `Resources/Locales/*.json`, `EdgeMark.xcodeproj`
