# Browser and desktop control

- Use the authenticated `playwright-extension` MCP server for all agent-driven
  browser tasks: navigation, signed-in workflows, page interaction, screenshots,
  visual QA, accessibility inspection, and console/network debugging.
- Use its `browser_*` MCP tools directly. Discover the tools and read a fresh
  snapshot before interacting with page elements.
- Computer Use MCP (`computer-use`) is the only browser fallback, and only when
  the extension is unavailable or cannot perform the required interaction.
  Use Computer Use MCP for non-browser desktop UI tasks.
- Never use Chrome DevTools MCP, CDP/remote-debugging connections, standalone
  Playwright MCP or CLI, Puppeteer, Selenium, agent-browser, or another browser
  controller. Do not launch an ad hoc browser script or shell wrapper instead.
- If the extension connection fails, reconnect the configured server, use
  Computer Use MCP as the fallback, or report the blocker. Do not install,
  enable, or configure an alternative controller or debugging port.
- Respect the extension's agent tab-group boundary. Open task tabs in that group;
  existing tabs must be shared into it. Never use another controller to reach
  unshared tabs.
- Manage your own group by convention, not through a session broker. Discover
  `browser_tab_group` when available. At the start of an independent session,
  inspect `current`, then name a fresh, session-specific group with `rename`.
  An empty group just created for this connection is suitable; do not reuse a
  group merely because its name contains "copilot".
- Keep the group ID/name and which tabs you opened in your session notes or
  checkpoint. Recheck `current` after reconnecting or losing that context; do
  not treat old tab indices as stable identities.
- If you notice another agent or unrelated tabs using your group, leave those
  tabs alone. Use `new` at your discretion, then `current` or `rename` to create
  and identify a fresh group. This leaves the old group/tabs untouched and keeps
  the signed-in profile. Do not disconnect other clients to obtain a group.
- `isolatedContext` is not a new tab group. Do not create another browser
  profile, add per-session MCP definitions, or build a broker/ownership registry.
  If group controls are unavailable, keep a known-safe group or report the
  limitation rather than taking over another task's tabs.
- Close tabs opened by you or your browser connection setup as soon as they are
  no longer needed, including the initial "connection was established"
  confirmation tab once the connection succeeds. Before finishing or handing
  off, close remaining task/temporary tabs unless the user asked to keep them
  open or they are still needed for ongoing work.
- Use the extension's tab-management tools to close individual tabs. Never close
  the whole browser, unrelated user tabs, tabs merely shared into your group,
  or tabs belonging to another agent.
- Inherit the authenticated machine-level `playwright-extension` configuration.
  Do not shadow it with repository or custom-agent MCP definitions. Keep browser
  tokens and other credentials in private local configuration, never in Git,
  instructions, logs, or generated examples.
- Existing permission and consequential-action confirmation requirements still
  apply. Do not grant blanket permissions to reduce prompts.
- This policy governs agent-driven browser control, including local UI review.
  Existing application scrapers, project test suites, and CI commands keep their
  normal purpose; do not repurpose them as interactive browser controllers.
  Ordinary HTTP/API requests and web search do not require browser automation,
  but must not be used to circumvent the browser-control policy.

# Cross-session coordination

- Use Copilot CLI's local peer session tools when another active session is
  using shared browser or desktop UI. Discover opted-in local sessions, send a
  concise message naming the blocked resource and your tab group or task, then
  continue independent work while waiting.
- Never take over, close, or modify another session's tabs or app state. Wait
  and retry after the peer signals completion; if no reply arrives, retry at a
  reasonable interval rather than asking the user to arbitrate temporary
  contention.
- When releasing a shared resource, message waiting peers promptly. This is a
  cooperative handoff mechanism, not a browser broker or ownership registry.

# Background helper processes

- Across projects, persistent background helpers and scheduled scripts must not
  open visible console or terminal windows. Do not rely solely on PowerShell's
  `-WindowStyle Hidden`; Windows Terminal can still open a blank window.
- Use `C:\code\dotfiles\windows\Get-BackgroundProcessHost.ps1` to build or locate
  the reusable console-free host. Set the task action to the returned executable
  and pass the actual console executable followed by its arguments. The host
  prevents console creation, waits for completion, and preserves the exit code.
- Keep helper diagnostics in log files. Preserve scheduled-task retries and
  duplicate-instance protection. Do not change the default terminal, hide normal
  interactive terminals, or make user-facing apps run invisibly.
