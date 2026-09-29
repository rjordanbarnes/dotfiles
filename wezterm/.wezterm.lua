-- Tracked in C:\code\dotfiles; commit and push changes there.
local wezterm = require 'wezterm'
local config = wezterm.config_builder()
local attention_dir = wezterm.home_dir .. '/.local/state/wezterm-attention'
local last_orphan_sweep = 0
local tab_refresh = false
local attention
local idle_ack_pending = {}
local attention_hook = wezterm.home_dir .. '/.copilot/hooks/wezterm-attention.ps1'

local function clear_attention_markers()
  for _, path in ipairs(wezterm.glob(attention_dir .. '/*')) do
    if path:match('[\\/](%d+)$') then
      os.remove(path)
    end
  end
end

local function acknowledge_idle(pane_id)
  if not pane_id then return false end

  pane_id = tostring(pane_id)
  if attention.get_attention(pane_id) ~= 'stop' then
    idle_ack_pending[pane_id] = nil
    return false
  end

  local now = os.time()
  if idle_ack_pending[pane_id] and now - idle_ack_pending[pane_id] < 2 then return false end
  idle_ack_pending[pane_id] = now

  local call_ok, success, _, stderr = pcall(wezterm.run_child_process, {
    'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
    '-NoLogo',
    '-NoProfile',
    '-File',
    attention_hook,
    'review',
    pane_id,
  })
  if not call_ok or not success then
    idle_ack_pending[pane_id] = nil
    wezterm.log_error(
      'failed to acknowledge idle pane ' .. pane_id .. ': '
        .. tostring(call_ok and stderr or success)
    )
    return false
  end

  return true
end

wezterm.on('gui-startup', function(command)
  clear_attention_markers()
  local _, _, window = wezterm.mux.spawn_window(command or {})
  window:gui_window():maximize()
end)

config.default_prog = { 'C:\\Program Files\\PowerShell\\7\\pwsh.exe', '-NoLogo' }
config.default_cwd = 'C:\\code'
config.font = wezterm.font_with_fallback {
  {
    family = 'Cascadia Mono',
    weight = 'Regular',
  },
  'Symbols Nerd Font Mono',
  'Segoe UI Emoji',
}
config.font_size = 12.0
config.front_end = 'WebGpu'
config.freetype_load_target = 'Light'
config.freetype_render_target = 'Normal'

config.initial_cols = 150
config.initial_rows = 42
config.window_padding = {
  left = 10,
  right = 10,
  top = 8,
  bottom = 8,
}
config.window_background_opacity = 1.0
config.inactive_pane_hsb = {
  saturation = 0.8,
  brightness = 0.65,
}

config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = false
config.show_new_tab_button_in_tab_bar = true
config.switch_to_last_active_tab_when_closing_tab = true
config.tab_max_width = 40
config.status_update_interval = 1000
config.audible_bell = 'Disabled'
config.keys = {
  {
    key = 'Enter',
    mods = 'SHIFT',
    action = wezterm.action.SendString '\x1b\r',
  },
  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      if window:get_selection_text_for_pane(pane) ~= '' then
        window:perform_action(wezterm.action.CopyTo 'Clipboard', pane)
      else
        window:perform_action(wezterm.action.SendKey { key = 'c', mods = 'CTRL' }, pane)
      end
    end),
  },
  {
    key = 'v',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local title = pane:get_title():lower()
      local awaiting_input = attention
        and attention.get_attention(pane:pane_id(), { dir = attention_dir }) == 'notify'

      if title:find('github copilot', 1, true) and not awaiting_input then
        window:perform_action(wezterm.action.SendKey { key = 'v', mods = 'ALT' }, pane)
      else
        window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
      end
    end),
  },
  {
    key = 't',
    mods = 'CTRL',
    action = wezterm.action.SpawnTab 'CurrentPaneDomain',
  },
  {
    key = 'w',
    mods = 'CTRL',
    action = wezterm.action.CloseCurrentTab { confirm = false },
  },
  {
    key = 'LeftArrow',
    mods = 'ALT',
    action = wezterm.action.ActivateTabRelative(-1),
  },
  {
    key = 'RightArrow',
    mods = 'ALT',
    action = wezterm.action.ActivateTabRelative(1),
  },
  {
    key = 'F2',
    mods = 'NONE',
    action = wezterm.action.PromptInputLine {
      description = 'Enter a tab name (leave blank to reset)',
      action = wezterm.action_callback(function(window, _, line)
        if line then
          window:active_tab():set_title(line)
        end
      end),
    },
  },
}

for index, key in ipairs { '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' } do
  table.insert(config.keys, {
    key = key,
    mods = 'ALT',
    action = wezterm.action.ActivateTab(index - 1),
  })
end

config.colors = {
  foreground = '#cccccc',
  background = '#0c0c0c',
  cursor_bg = '#ffffff',
  cursor_border = '#ffffff',
  cursor_fg = '#0c0c0c',
  selection_bg = '#ffffff',
  selection_fg = '#0c0c0c',
  ansi = {
    '#0c0c0c',
    '#c50f1f',
    '#13a10e',
    '#c19c00',
    '#0037da',
    '#881798',
    '#3a96dd',
    '#cccccc',
  },
  brights = {
    '#767676',
    '#e74856',
    '#16c60c',
    '#f9f1a5',
    '#3b78ff',
    '#b4009e',
    '#61d6d6',
    '#f2f2f2',
  },
  tab_bar = {
    background = '#1f1f1f',
    active_tab = {
      bg_color = '#0c0c0c',
      fg_color = '#f2f2f2',
      intensity = 'Bold',
    },
    inactive_tab = {
      bg_color = '#2b2b2b',
      fg_color = '#cccccc',
    },
    inactive_tab_hover = {
      bg_color = '#3a3a3a',
      fg_color = '#f2f2f2',
    },
    new_tab = {
      bg_color = '#1f1f1f',
      fg_color = '#cccccc',
    },
    new_tab_hover = {
      bg_color = '#3a3a3a',
      fg_color = '#f2f2f2',
    },
  },
}

attention = wezterm.plugin.require 'https://github.com/pro-vi/wezterm-attention'

local attention_indicators = {
  thinking_frames = { '◌ ', '◔ ', '◑ ', '◕ ' },
  stop = '💤 ',
  notify = '🔔 ',
  review = utf8.char(0xf04b2) .. ' ',
}

attention.apply_to_config(config, {
  dir = attention_dir,
  auto_poll = false,
  format_tab_title = false,
  review_key = false,
  colors = {
    thinking = '#2b2148',
    stop = false,
    notify = false,
    review = false,
  },
  indicators = attention_indicators,
  -- Review is unused here, so reuse it for acknowledged idle tabs.
  auto_clear = {},
  stale_after_ms = {
    thinking = 30 * 60 * 1000,
    stop = 4 * 60 * 60 * 1000,
    notify = false,
  },
})

wezterm.on('format-tab-title', function(tab, _, _, _, hover)
  local best_state, best_frame, best_priority
  local priorities = { thinking = 1, review = 2, stop = 3, notify = 4 }

  for _, pane in ipairs(tab.panes) do
    local state, frame = attention.get_attention(pane.pane_id)
    local priority = priorities[state] or 0
    if priority > (best_priority or 0) then
      best_state, best_frame, best_priority = state, frame, priority
    end
  end

  local indicator = attention_indicators[best_state] or ''
  if best_state == 'thinking' then
    local frames = attention_indicators.thinking_frames
    indicator = frames[((best_frame or 0) % #frames) + 1]
  end

  local title = tab.tab_title and tab.tab_title ~= '' and tab.tab_title or tab.active_pane.title
  local label = string.format('%d: %s ', tab.tab_index + 1, title)
  if best_state == 'review' then
    return {
      { Foreground = { Color = '#767676' } },
      { Text = ' ' .. indicator },
      { Foreground = { Color = (tab.is_active or hover) and '#f2f2f2' or '#cccccc' } },
      { Text = label },
    }
  end

  if best_state == 'thinking' then
    return {
      { Background = { Color = '#2b2148' } },
      { Text = ' ' .. indicator .. label },
    }
  end

  return ' ' .. indicator .. label
end)

wezterm.on('update-status', function(window, pane)
  local live_panes = {}

  attention.poll(window)
  if pane and acknowledge_idle(pane:pane_id()) then
    attention.poll(window)
  end

  for _, tab in ipairs(window:mux_window():tabs()) do
    for _, pane in ipairs(tab:panes()) do
      local pane_id = tostring(pane:pane_id())
      live_panes[pane_id] = true
      local state = attention.get_attention(pane:pane_id())

      if state and state ~= 'notify' and state ~= 'stop' and state ~= 'review' then
        attention.remove_marker(pane:pane_id())
      end
    end
  end

  local now = os.time()
  if now - last_orphan_sweep >= 10 then
    for _, path in ipairs(wezterm.glob(attention_dir .. '/*')) do
      local pane_id = path:match('[\\/](%d+)$')
      if pane_id and not live_panes[pane_id] then
        os.remove(path)
      end
    end
    last_orphan_sweep = now
  end

  -- Force tab-title refresh; remove when WezTerm exposes tab invalidation.
  tab_refresh = not tab_refresh
  window:set_right_status(utf8.char(tab_refresh and 0x200b or 0x200c))
end)

return config
