# Main sidebar

The left sidebar shows the user's projects and nothing else, as one tree.
This page fixes the names of its parts so that code, scripts and
conversations use the same words.

Source: `src/ui/sidebar.zig` (drawing and interaction) and `src/projects.zig`
(the model and its persistence in `~/.tt_projects`).

## Elements

| Element | Name in the code | What it is |
|---|---|---|
| The panel | `Sidebar` | The projects tree. While the Settings tab is in front, the same panel is that tab's navigation menu instead. |
| Top strip | header | Carries the "+" that adds a folder as a project. |
| First row | default project (`Projects.default_name`, shown as "Default project") | The tabs and resources that belong to no folder. Drawn like any project. Its own tabs are group id 0. |
| Folder row | `Project` | A folder with tabs of its own, plus a name, a root directory, an optional icon, a jump key and an open/folded state. |
| Child row | `Resource` | Something kept at hand under a project. Each resource owns its own set of tabs. |
| Child row, kind `.shells` | shell group | A group of shells that start in a directory. Named "Shells", "Shells 2", … by default. |
| Child row, kind `.file` | file (pinned file) | A file worth keeping at hand, named by its path relative to the project. |

The default project has resources too, exactly like a folder project.

## Parts on and around the rows

| Part | What it is |
|---|---|
| Shown row | The row whose tabs are currently in the tab strip. |
| Icon | A symbol or a coloured dot the user sets on a project or a resource (`ui/icon_spec.zig`). |
| "New tab" terminal | The only button on a row, shown on hover. It opens a new tab in that row's own tabs. |
| Context menu | The right-click menu. Its targets are `project`, `default_project` and `resource` (`MenuTarget`). New shell groups, renaming, the icon and removing live here. |
| Toggle | The collapse button. When the sidebar is collapsed nothing of it stays on screen except this toggle, which moves into the titlebar band next to the traffic lights. |
| Edge | The right border, dragged to resize the sidebar. |
| Drop indicator | The line shown while a row is dragged to reorder projects or to move a resource within or between projects. |
| Drop target | A row lit while a tab dragged from a strip (or a file dragged from the files panel) is over it. A tab let go there joins that row's own tabs (`Result.drop_tab`): a project row its own, a resource row the resource's. The row the tab is already in is not a target. The tab menu's "Move to…" lists the same rows. |
| Hints | The ⌥ jump-key letters and digits drawn on rows (`Hints`). |

## Model notes

- Projects and resources share one id space, so any id names one thing. Ids
  start at 1; 0 is the default project's own tabs.
- Ids are handed out afresh on every load, so nothing on disk refers to them.
- A project's jump key is handed out once and then kept, whatever the order
  or the name becomes.
- A new shell opened from a resource starts in the resource's directory: the
  file's folder for a file, the group's directory for a shell group.
