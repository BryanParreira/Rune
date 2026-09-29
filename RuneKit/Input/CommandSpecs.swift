import Foundation

/// A tool's subcommands and flags, for Tab completion. Written for Rune; deliberately small:
/// the everyday parts of each tool, each with a one-line description.
public struct CommandSpec: Sendable {
    public struct Flag: Sendable {
        public let name: String
        public let description: String
    }

    public let name: String
    public var aliases: [String] = []
    public var description: String?
    public var subcommands: [CommandSpec] = []
    public var flags: [Flag] = []
    /// Values for the argument position (branches, scripts, targets…).
    public var values: (@Sendable (CommandCompletion.Sources, String) -> [String])?
}

private func cmd(_ name: String, _ description: String? = nil, aliases: [String] = [], flags: [(String, String)] = [],
                 values: (@Sendable (CommandCompletion.Sources, String) -> [String])? = nil,
                 _ subcommands: [CommandSpec] = []) -> CommandSpec {
    CommandSpec(name: name, aliases: aliases, description: description, subcommands: subcommands,
                flags: flags.map { CommandSpec.Flag(name: $0.0, description: $0.1) }, values: values)
}

private let branches: @Sendable (CommandCompletion.Sources, String) -> [String] = { $0.gitBranches($1) }
private let scripts: @Sendable (CommandCompletion.Sources, String) -> [String] = { $0.packageScripts($1) }
private let targets: @Sendable (CommandCompletion.Sources, String) -> [String] = { $0.makeTargets($1) }

public enum CommandSpecs {
    public static let all: [String: CommandSpec] = {
        var table: [String: CommandSpec] = [:]
        for spec in [git, docker, npm, yarn, pnpm, brew, kubectl, cargo, swift, gh, pip, make] {
            table[spec.name] = spec
            for alias in spec.aliases { table[alias] = spec }
        }
        table["pip3"] = pip
        return table
    }()

    static let git = cmd("git", "Version control", [
        cmd("add", "Stage changes", flags: [("-A", "Stage everything"), ("-p", "Pick hunks interactively"), ("-u", "Stage tracked files only")]),
        cmd("branch", "List, create or delete branches", flags: [("-a", "Include remote branches"), ("-d", "Delete a merged branch"), ("-D", "Force-delete a branch"), ("-m", "Rename a branch"), ("-v", "Show last commit")], values: branches),
        cmd("checkout", "Switch branches or restore files", flags: [("-b", "Create and switch to a branch"), ("--", "Restore files")], values: branches),
        cmd("switch", "Switch branches", flags: [("-c", "Create and switch"), ("-", "Previous branch")], values: branches),
        cmd("clone", "Copy a repository", flags: [("--depth", "Shallow clone"), ("--branch", "Check out a branch")]),
        cmd("commit", "Record staged changes", flags: [("-m", "Message"), ("-a", "Stage tracked changes first"), ("--amend", "Rewrite the last commit"), ("--no-edit", "Keep the message"), ("--fixup", "Fixup for a commit")]),
        cmd("diff", "Show changes", flags: [("--staged", "Staged changes"), ("--stat", "Summary"), ("--name-only", "Changed file names")], values: branches),
        cmd("fetch", "Download from a remote", flags: [("--all", "All remotes"), ("--prune", "Drop deleted remote branches")]),
        cmd("init", "Create a repository"),
        cmd("log", "Commit history", flags: [("--oneline", "One line each"), ("--graph", "Branch graph"), ("-n", "Limit count"), ("-p", "With diffs"), ("--stat", "With file stats")], values: branches),
        cmd("merge", "Join branches", flags: [("--no-ff", "Always create a merge commit"), ("--abort", "Stop a conflicted merge"), ("--squash", "Squash into one change")], values: branches),
        cmd("pull", "Fetch and integrate", flags: [("--rebase", "Rebase instead of merge"), ("--ff-only", "Fast-forward only")]),
        cmd("push", "Upload commits", flags: [("-u", "Set upstream"), ("--force-with-lease", "Force safely"), ("--tags", "Push tags"), ("--delete", "Delete a remote branch")], values: branches),
        cmd("rebase", "Reapply commits on another base", flags: [("-i", "Interactive"), ("--continue", "Continue after resolving"), ("--abort", "Cancel the rebase"), ("--onto", "New base")], values: branches),
        cmd("remote", "Manage remotes", flags: [("-v", "Show URLs")], [
            cmd("add", "Add a remote"), cmd("remove", "Remove a remote"), cmd("rename", "Rename a remote"), cmd("set-url", "Change a remote URL"),
        ]),
        cmd("reset", "Move HEAD / unstage", flags: [("--soft", "Keep changes staged"), ("--hard", "Discard changes"), ("--mixed", "Keep changes unstaged")], values: branches),
        cmd("restore", "Restore files", flags: [("--staged", "Unstage"), ("--source", "From a commit")]),
        cmd("revert", "Undo a commit with a new one", flags: [("--no-edit", "Keep the message")]),
        cmd("show", "Show a commit", flags: [("--stat", "File stats")], values: branches),
        cmd("stash", "Shelve changes", flags: [("-u", "Include untracked"), ("-m", "Message")], [
            cmd("list", "List stashes"), cmd("pop", "Apply and drop"), cmd("apply", "Apply and keep"), cmd("drop", "Drop a stash"), cmd("show", "Show a stash"), cmd("clear", "Drop all stashes"),
        ]),
        cmd("status", "Working tree status", flags: [("-s", "Short format"), ("-b", "Show branch")]),
        cmd("tag", "Create or list tags", flags: [("-a", "Annotated tag"), ("-d", "Delete a tag"), ("-l", "List tags")]),
        cmd("cherry-pick", "Apply a commit here", flags: [("--continue", "Continue"), ("--abort", "Cancel")]),
        cmd("worktree", "Extra working trees", [cmd("add", "New worktree"), cmd("list", "List worktrees"), cmd("remove", "Remove a worktree")]),
    ])

    static let docker = cmd("docker", "Containers", [
        cmd("build", "Build an image", flags: [("-t", "Name and tag"), ("-f", "Dockerfile path"), ("--no-cache", "Build from scratch"), ("--platform", "Target platform")]),
        cmd("compose", "Multi-container apps", [
            cmd("up", "Start services", flags: [("-d", "In the background"), ("--build", "Rebuild images")]),
            cmd("down", "Stop and remove", flags: [("-v", "Remove volumes")]),
            cmd("logs", "Service logs", flags: [("-f", "Follow")]),
            cmd("ps", "List services"), cmd("build", "Build services"), cmd("pull", "Pull images"), cmd("restart", "Restart services"),
            cmd("exec", "Run in a service"),
        ]),
        cmd("exec", "Run in a container", flags: [("-it", "Interactive terminal"), ("-e", "Environment variable"), ("-u", "User")]),
        cmd("images", "List images", flags: [("-a", "All images")]),
        cmd("logs", "Container logs", flags: [("-f", "Follow"), ("--tail", "Last lines")]),
        cmd("ps", "List containers", flags: [("-a", "Include stopped"), ("-q", "IDs only")]),
        cmd("pull", "Download an image"), cmd("push", "Upload an image"),
        cmd("rm", "Remove containers", flags: [("-f", "Force")]),
        cmd("rmi", "Remove images", flags: [("-f", "Force")]),
        cmd("run", "Run a container", flags: [("-it", "Interactive terminal"), ("-d", "In the background"), ("--rm", "Remove when done"), ("-p", "Publish a port"), ("-v", "Mount a volume"), ("-e", "Environment variable"), ("--name", "Container name")]),
        cmd("start", "Start containers"), cmd("stop", "Stop containers"), cmd("restart", "Restart containers"),
        cmd("system", "Docker system", [cmd("prune", "Remove unused data", flags: [("-a", "Include unused images")]), cmd("df", "Disk usage")]),
        cmd("volume", "Volumes", [cmd("ls", "List"), cmd("rm", "Remove"), cmd("prune", "Remove unused")]),
        cmd("network", "Networks", [cmd("ls", "List"), cmd("create", "Create"), cmd("rm", "Remove")]),
    ])

    private static func nodePackageManager(_ name: String, install: String) -> CommandSpec {
        cmd(name, "Node packages", [
            cmd(install, "Install dependencies", aliases: name == "npm" ? ["i"] : [], flags: [("-D", "As a dev dependency"), ("-g", "Globally")]),
            cmd("run", "Run a package.json script", values: scripts),
            cmd("test", "Run tests"), cmd("start", "Start the app"), cmd("init", "Create package.json"),
            cmd("uninstall", "Remove a package", aliases: name == "npm" ? ["rm"] : []),
            cmd("update", "Update packages"), cmd("outdated", "Show outdated packages"), cmd("publish", "Publish the package"),
            cmd("exec", "Run a package binary"), cmd("ci", "Clean install from the lockfile"),
        ])
    }

    static let npm = nodePackageManager("npm", install: "install")
    static let yarn = nodePackageManager("yarn", install: "add")
    static let pnpm = nodePackageManager("pnpm", install: "add")

    static let brew = cmd("brew", "Homebrew", [
        cmd("install", "Install a formula or cask", flags: [("--cask", "Install an app")]),
        cmd("uninstall", "Remove a formula"), cmd("upgrade", "Upgrade packages"), cmd("update", "Update Homebrew"),
        cmd("list", "Installed packages"), cmd("search", "Search packages"), cmd("info", "Package details"),
        cmd("outdated", "Packages with updates"), cmd("cleanup", "Remove old versions"), cmd("doctor", "Check for problems"),
        cmd("services", "Background services", [cmd("list", "List services"), cmd("start", "Start"), cmd("stop", "Stop"), cmd("restart", "Restart")]),
        cmd("tap", "Add a repository"),
    ])

    static let kubectl = cmd("kubectl", "Kubernetes", [
        cmd("get", "List resources", flags: [("-n", "Namespace"), ("-A", "All namespaces"), ("-o", "Output format"), ("-w", "Watch")]),
        cmd("describe", "Show details", flags: [("-n", "Namespace")]),
        cmd("apply", "Apply a configuration", flags: [("-f", "File or folder"), ("-k", "Kustomize folder")]),
        cmd("delete", "Delete resources", flags: [("-f", "File"), ("-n", "Namespace")]),
        cmd("logs", "Pod logs", flags: [("-f", "Follow"), ("-n", "Namespace"), ("-c", "Container"), ("--tail", "Last lines")]),
        cmd("exec", "Run in a pod", flags: [("-it", "Interactive terminal"), ("-n", "Namespace")]),
        cmd("port-forward", "Forward a local port"),
        cmd("config", "kubeconfig", [cmd("get-contexts", "List contexts"), cmd("use-context", "Switch context"), cmd("current-context", "Show context")]),
        cmd("rollout", "Manage rollouts", [cmd("status", "Rollout status"), cmd("restart", "Restart"), cmd("undo", "Roll back")]),
        cmd("scale", "Change replicas"),
    ])

    static let cargo = cmd("cargo", "Rust", [
        cmd("build", "Compile", flags: [("--release", "Optimized")]), cmd("run", "Build and run", flags: [("--release", "Optimized")]),
        cmd("test", "Run tests"), cmd("check", "Check without building"), cmd("add", "Add a dependency"), cmd("new", "New package"),
        cmd("fmt", "Format code"), cmd("clippy", "Lint"), cmd("update", "Update dependencies"), cmd("doc", "Build docs"), cmd("clean", "Remove build output"),
    ])

    static let swift = cmd("swift", "Swift", [
        cmd("build", "Build the package", flags: [("-c", "Configuration (debug/release)")]), cmd("run", "Build and run"),
        cmd("test", "Run tests", flags: [("--filter", "Only matching tests")]),
        cmd("package", "Package commands", [cmd("init", "New package"), cmd("update", "Update dependencies"), cmd("resolve", "Resolve dependencies"), cmd("clean", "Remove build output")]),
    ])

    static let gh = cmd("gh", "GitHub", [
        cmd("pr", "Pull requests", [cmd("create", "Open a PR"), cmd("list", "List PRs"), cmd("view", "Show a PR"), cmd("checkout", "Check out a PR"), cmd("merge", "Merge a PR"), cmd("status", "Your PRs")]),
        cmd("issue", "Issues", [cmd("create", "Open an issue"), cmd("list", "List issues"), cmd("view", "Show an issue")]),
        cmd("repo", "Repositories", [cmd("clone", "Clone"), cmd("create", "Create"), cmd("view", "Show")]),
        cmd("release", "Releases", [cmd("create", "Publish a release"), cmd("list", "List releases"), cmd("view", "Show a release")]),
        cmd("run", "Workflow runs", [cmd("list", "List runs"), cmd("view", "Show a run"), cmd("watch", "Follow a run")]),
        cmd("auth", "Authentication", [cmd("login", "Log in"), cmd("status", "Show status")]),
    ])

    static let pip = cmd("pip", "Python packages", [
        cmd("install", "Install packages", flags: [("-r", "From a requirements file"), ("-U", "Upgrade"), ("-e", "Editable install")]),
        cmd("uninstall", "Remove packages"), cmd("list", "Installed packages"), cmd("freeze", "Requirements output"), cmd("show", "Package details"),
    ])

    static let make = cmd("make", "Build targets", values: targets)
}
