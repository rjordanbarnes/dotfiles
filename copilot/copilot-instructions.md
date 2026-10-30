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
