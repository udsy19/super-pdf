// UpdateKit (engine, docs/ARCHITECTURE.md "Engines"). The GitHub Releases updater: check, SHA-256 and code-signature
// verification, staging, the swap on quit or when idle. The app target registers it as `Services.updates`.
//
// Empty until WP0a fills it, adapted from super-flow Sources/UpdateKit/*. Copied files credit their origin in a header
// comment; fixes made in a sister repo are ported here by hand. No app policy: no `Services`, no `Defaults`, no UI
// strings; configuration comes in through initialisers.
