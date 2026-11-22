# Repository view

The repository view is a git client for one repository, in a tab of its own:
its history as a graph, what is staged and what is not, its stashes, and its
pull requests on the host it is pushed to. This page fixes the names of its
parts so that code, scripts and conversations use the same words.

It is opened from the command palette (⌘K → "Git: Open repository",
`App.Action.open_repository`) for the folder the files panel shows. A tab
already open on that repository is brought forward instead of opened twice.

Source: `src/features/repo/`. The tab is `entry/tab.zig` (kind `repo`); each
view below is one file in `view/`; everything that runs git or talks to a
host is in `client/`; the data they exchange is in `model/`. How those
folders may depend on each other is in `CLAUDE.md` › Features.

The files panel's Git view (the right sidebar's "Git" strip) is the same
feature in a narrower shape: `view/panel.zig`, mounted by `entry/panel.zig`.
What this page says about committing applies to both.

## Elements

| Element | Name in the code | What it is |
|---|---|---|
| The tab | `RepoTab` | One repository. Its title is the repository's folder name; its context line is the branch and how far it is ahead of and behind its upstream ("main ↑1 ↓2"). |
| Left column | navigation (`view/nav.zig`) | The four views of the workspace with their counts, then Branches, Remotes and Tags. Pull, Push and Fetch live here, on the rows they are about. |
| View | `Section` | What the navigation switches between: `changes`, `history`, `pulls`, `stashes`. The tab comes back on the one it was left on. |
| History | `view/history.zig` | The commits, newest first, with the graph. |
| Commit detail | `view/commit_detail.zig` | The selected commit, in a pane at the right of History. |
| Changes | `view/changes.zig` | Staging, the commit composer, and the selected file's diff. |
| Stashes | `view/stashes.zig` | The stash list. |
| Pull Requests | `view/pulls.zig` | The host's pull requests for this repository. |
| Pull request | `view/pull_detail.zig` | One pull request looked at closely. It takes the place of the list until "Pull Requests" (back) is pressed. |

## Navigation

| Part | What it is |
|---|---|
| Workspace rows | Changes (count of changed files), History, Pull Requests (count of open ones, once the host has answered), Stashes (count). |
| Branches | The local branches. The one checked out is ticked. A double click checks a branch out. |
| Pull / Push | Two small buttons at the right of the checked-out branch's row, each with the number of commits it would move (behind, ahead), in the accent colour when there is something to move. Pull needs an upstream; Push publishes a branch that has none. No other branch has them. |
| "+" | Opens a name field under the heading; ↵ creates the branch at HEAD and checks it out, Esc or a click elsewhere closes it. |
| Remotes | Each remote by name, with the remote branches that have no local one under it. A double click checks one out as a local branch tracking it. |
| Fetch | A small button at the right of each remote's row: fetches that remote (`git fetch --prune <remote>`). |
| Status line | At the foot of the column: what is under way ("Pulling…"), or in red what the last command that failed said. |
| Tags | The newest tags (up to 40). |

## History

| Part | What it is |
|---|---|
| Filter box | Keeps the commits whose subject, author, hash or ref names contain the text. While it holds text the graph is not drawn: the rows left are no longer neighbours. |
| Graph | A lane per line of history, one colour per lane. The line of first parents keeps to the left; a branch bends into and out of it. Laid out in `model/lanes.zig`. |
| Ref chips | The names pointing at a commit, after its subject: the branch checked out (accent), other local branches, remote branches (grey), tags (amber). |
| Author | Initials in a circle, with the name beside it when the list is wide enough. |
| Density | The list follows Settings › UI › Mode. Regular: 44pt rows, lanes 16pt apart, a 2pt stroke. Compact (`theme.compact`): 26pt rows, a shorter header and filter bar, lanes 11pt apart, a 1.5pt stroke, smaller dots and author circles. All sizes come from `Metrics` in `view/history.zig`; fonts are the same in both. |
| Row menu | A secondary click on a commit selects it and offers "Copy Commit Message" (the subject, a blank line, the rest) and "Copy SHA" (the full hash). |
| Row | A click selects the commit; ↑ and ↓ move the selection; ⌘C copies the selected commit's hash. Scrolling near the end asks for the next page (300 commits a page). |
| Detail pane | Hash, subject and body, author, date, parents, refs, and the files with their `+n −n`. A click on a file opens it against the commit's first parent in a diff tab. |
| Selecting text | Everything written in the detail pane (hash, subject, message, author, date, parents, refs) can be selected and copied: drag across it, double-click a word, triple-click a line, then ⌘C or a secondary click → Copy. The helper is `view/select.zig`. With nothing selected, ⌘C copies the commit's hash. |
| File menu | The files are buttons, so they are not selectable: a secondary click on one offers "Copy Path" and "Copy Absolute Path". |
| Checkout / Revert / Cherry-pick | The three buttons under the detail. Each asks first. Checkout leaves HEAD detached at the commit. |

## Changes

| Part | What it is |
|---|---|
| Staged / Unstaged | The two lists, each with "Unstage all" / "Stage all". Conflicts get a list of their own above them. |
| Checkbox | Stages or unstages the file. A click elsewhere on the row selects it instead. |
| Status letter | `A` added, `M` modified, `D` deleted, `R` renamed, `U` not in git yet, `!` in conflict. |
| Diff | The selected file's change as a unified diff: hunk headers, added and removed lines tinted, one gutter of line numbers. |
| Unified / Split | Unified is this pane. "Split" opens the same change side by side in a diff tab. |
| Discard | Throws an unstaged change away, after asking. |
| Composer | "Commit message": a summary, an optional description, "Amend last commit", and how many files are staged. ↵ in the summary commits. |
| Commit button | One button naming the branch ("Commit on main"), with an arrow inside its right end (`kit.splitButton`). With nothing staged it reads "Commit all on …" and stages everything first. |

### Commit options

The arrow inside the commit button opens a menu of three options. The ones
in force are ticked.

| Option | What it does |
|---|---|
| Amend | The next commit replaces the last one (`--amend`). With the message left empty the last commit keeps its own (`--no-edit`). The button reads "Amend" while it is on, and it goes off again once the commit is made. Same switch as the "Amend last commit" checkbox. |
| Signoff | Adds a `Signed-off-by` line (`--signoff`). Stays on for later commits. |
| Skip Hooks | Skips the pre-commit and commit-msg hooks (`--no-verify`). Stays on for later commits. |

⌘⇧↵ (`App.Action.commit_amend`, also "Git: Amend last commit" in the
palette) turns Amend on, and makes the commit when it is already on. It
applies while the Git view's message box has the keyboard, or while Changes
is the view in front.

### When a commit fails

The line under the button shows the first line of what git said. Everything
else (a hook's report) is written to
`$TMPDIR/tt/commit-output-<repository>.txt` and opened in a tab: the command
as it would be typed, its exit status, then all it printed. One file per
repository, so the next failure rewrites it and the tab already open follows.

## Stashes

"Stash changes" puts everything away, new files included. Each stash has
"Apply" (bring it back and drop it from the list) and "Drop" (throw it away,
after asking).

## Pull requests

| Part | What it is |
|---|---|
| Filter box | Keeps the rows whose title, author or branch contains the text. |
| State pills | Open, Merged, Closed: which list is asked of the host. |
| Saved filters | Everyone's, Created by me, Waiting for my review. Shown once the host has said who the account is. |
| Row | Title, `head → base` (or "Draft"), number, who opened it and when; at the right its checks, what the reviewers said, its comments and its size. The right-hand part fills in as each row on show is looked at closely. |
| Header | Back, the number, the title and state, "who wants to merge N commits from A into B", "Open on host", "Checkout". |
| Files column | The files the pull request changes. |
| Diff | The selected file's change, with each comment thread under the line it is about. |
| Thread | The first comment and its replies, a box to reply (↵ sends), and "Resolve" where the host can. |
| Reviewers | Each reviewer and what they said: approved, changes requested, commented, or still waiting. |
| Labels | In the label's own colour. Not shown for a host without labels. |
| Checks | The checks of the head commit, each with its state and how long it ran. |
| Merge box | Whether it merges cleanly, the merge button (the chosen way, with an arrow inside it for the others), and "Update with <base>" where the host can. Merging asks first. |

### Where the data comes from

- Which host: read from the remote's address (`model/remote_url.zig`), `origin`
  when there is one by that name, else the first remote.
- Which account: the one for that host in Settings › Git › Hosting
  (`entry/settings.zig`), kept in the `accounts:` section of `~/.tt/config.yml`.
  A token is written there, or taken when needed from `gh`, `glab` or git's
  credential helper.
- Nothing is sent to a host before the Pull Requests view is first shown, and
  nothing at all without an account for it: the view then says what is missing.
- A pull request's files, diffs and commit count are read with git on this
  Mac after fetching its head (`client/pull_files.zig`), the same for every
  host. The host supplies the rest: metadata, reviewers, checks, threads.

### What each host can do

| | GitHub | GitLab | Bitbucket Cloud | Gitea / Forgejo |
|---|---|---|---|---|
| Called | pull request | merge request | pull request | pull request |
| Ways to merge | squash, merge, rebase | merge, squash | merge, squash, fast-forward | merge, squash, rebase |
| Update branch | merges the base in | rebase | not offered | rebase |
| Reply to a thread | yes | yes | yes | no |
| Resolve a thread | no | yes | yes | no |
| Threads shown | yes | yes | yes | no |
| Labels | yes | yes | no | yes |
| Checks | check runs and statuses | the pipeline, as one check | build statuses | commit statuses |

A control a host has no answer for is not drawn (`Capabilities` in
`model/pull_request.zig`).

## Model notes

- Every git command on the repository goes through `client/git.zig`: `Repo`
  for what changes it (one queue, off the UI's thread, one command at a time)
  and `Query` for what only reads.
- A view runs nothing. It is shown data and returns what the user asked for
  as an intent; the tab hands that to the client.
- Requests to a host are sent only by `client/forge.zig`. Each of
  `client/github.zig`, `gitlab.zig`, `bitbucket.zig` and `gitea.zig` only
  builds requests and decodes answers into the shared model.
- Questions that need a box or a menu (revert, discard, merge, the commit
  options) go to the app through `Env.askConfirm` / `Env.askMenu` /
  `Env.askChecks` and come back through the tab's `answered` hook.
- Across relaunches the tab keeps one record, `repo <folder> <view>`.
- Colours are the theme's tokens, so the view follows every style.
