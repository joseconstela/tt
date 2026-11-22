//! The repository feature: git for the folder on show. This file is the
//! feature's public surface, the only one code outside `features/repo/`
//! may import (`tooling/arch_check.zig` holds everyone to it).
//!
//! Inside, by what a file is allowed to do:
//!   model/   data and parsing; imports nothing but `std` and `model/`
//!   client/  everything that runs git, through the hosts it is handed
//!   view/    drawing; reads model data, returns what the user asked for
//!   entry/   what the app mounts: a view and its client put together
//!   hosts.zig  the effects the feature is handed (running a command)
//!
//! It is the Git view of the files panel (`Panel`), the colours and
//! letters the files tree takes from a reading (`Kind`, `kindColor`,
//! `kindLetter`), and the repository tab (`Tab`, added to the tab manager
//! by `register`): history with its graph, staging and commits, stashes.
const view = @import("view/panel.zig");
const status = @import("model/status.zig");
const tab_mod = @import("../../tabs/tab.zig");

/// The hosting accounts: the `accounts:` section of config.yml, which
/// `config.zig` hands over line by line.
pub const Accounts = @import("client/accounts.zig").Accounts;
pub const Account = @import("client/accounts.zig").Account;

/// Settings › Git › Hosting: the accounts, edited (a page of the settings tab).
pub const SettingsPage = @import("entry/settings.zig").Page;

/// The repository tab (the app asks one whether it already `shows` a folder).
pub const Tab = @import("entry/tab.zig").RepoTab;

/// Adds the `repo` kind to the tab manager.
pub fn register(manager: *tab_mod.TabManager) void {
    manager.register(.{ .name = "repo", .label = "Repository", .create = Tab.create });
}

/// The Git view, as the files panel mounts it.
pub const Panel = @import("entry/panel.zig").Panel;
/// What a draw of the view hands the app: a comparison to open, a box or
/// a menu to show.
pub const Result = view.Result;
pub const Diff = view.Diff;
pub const Confirm = view.Confirm;
pub const Menu = view.Menu;

/// How a path shows in the tree, and the colour and letter that go with it.
pub const Kind = status.Kind;
pub const kindColor = view.kindColor;
pub const kindLetter = view.kindLetter;
pub const font_badge = view.font_badge;

test {
    _ = @import("model/status.zig");
    _ = @import("model/log.zig");
    _ = @import("model/lanes.zig");
    _ = @import("model/reltime.zig");
    _ = @import("model/patch.zig");
    _ = @import("model/pull_request.zig");
    _ = @import("model/remote_url.zig");
    _ = @import("model/link_header.zig");
    _ = @import("client/git.zig");
    _ = @import("client/history.zig");
    _ = @import("client/worktree.zig");
    _ = @import("client/wire.zig");
    _ = @import("client/github.zig");
    _ = @import("client/gitlab.zig");
    _ = @import("client/bitbucket.zig");
    _ = @import("client/gitea.zig");
    _ = @import("client/accounts.zig");
    _ = @import("client/forge.zig");
    _ = @import("client/pull_files.zig");
    _ = @import("view/kit.zig");
    _ = @import("entry/tab.zig");
    _ = @import("entry/settings.zig");
}
