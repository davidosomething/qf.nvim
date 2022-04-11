local api = vim.api
local cmd = vim.cmd
local fn = vim.fn
local bo = vim.bo
local wo = vim.wo

local list_defaults = {
  auto_close = true, -- Automatically close location/quickfix list if empty
  auto_follow = 'prev', -- Follow current entry, possible values: prev,next,nearest, or false to disable
  auto_follow_limit = 8, -- Do not follow if entry is further away than x lines
  follow_slow = true, -- Only follow on CursorHold
  auto_open = true, -- Automatically open list on QuickFixCmdPost
  auto_resize = true, -- Auto resize and shrink location list if less than `max_height`
  max_height = 8, -- Maximum height of location/quickfix list
  min_height = 5, -- Minimum height of location/quickfix list
  wide = false, -- Open list at the very bottom of the screen, stretching the whole width.
  number = false, -- Show line numbers in list
  relativenumber = false, -- Show relative line numbers in list
  unfocus_close = false, -- Close list when window loses focus
  focus_open = false, -- Auto open list on window focus if it contains items
}

--- @class config
--- @field c List
--- @field l List
--- @field close_other boolean #Close other list kind on open. If location list opens, qf closes, and vice-versa
--- @field pretty boolean #Use a pretty printed format function for the quickfix lists
--
--- @class List
--- @field auto_close boolean #Close the list if empty
--- @field auto_follow string|boolean #Follow current entries. Possible strategies: prev,next,nearest or false to disable
--- @field auto_follow_limit number #limit the distance for the auto follow
--- @field follow_slow boolean #debounce following to `updatetime`
--- @field auto_open boolean #Open list on QuickFixCmdPost, e.g; grep
--- @field auto_resize boolean #Grow or shrink list according to items
--- @field max_height number #Auto resize max height
--- @field min_height number #Auto resize min height
--- @field wide boolean #Open list at the very bottom of the screen
--- @field number boolean #Show line numbers in window
--- @field relativenumber boolean #Show relative line number in window
--- @field unfocus_close boolean #Close list when parent window loses focus
--- @field focus_open boolean #Pair with `unfocus_close`, open list when parent window focuses
local defaults = {
  c = list_defaults,
  l = list_defaults,
  close_other = false,
  pretty = true
}

local M = { config = defaults }

local utils = require("qf.utils")

local fix_list = utils.fix_list
local list_items = utils.list_items
local get_height = utils.get_height

local post_commands = {
  'make', 'grep', 'grepadd', 'vimgrep', 'vimgrepadd',
  'cfile', 'cgetfile', 'caddfile', 'cexpr', 'cgetexpr',
  'caddexpr', 'cbuffer', 'cgetbuffer', 'caddbuffer'
}

local function list_post_commands(l)
  if l == "l" then
    return vim.tbl_map(
      -- Remove prefix c and prepend l
      function(val) if val:sub(1,1) == 'c' then
        return 'l'..val:sub(2)
      else
        return 'l' .. val end
      end
      , post_commands)
  else
    return post_commands
  end
end

local function istrue(val)
  return val == true or val == '1'
end

--- @param config config
function M.setup(config)
  config = config or {}
  M.config = vim.tbl_deep_extend('force', defaults, config)
  M.saved = {}

  if M.config.pretty then
    vim.opt.quickfixtextfunc = "QfFormat"
    M.setup_syntax = function() vim.cmd(utils.setup_syntax()) end
  else
    M.setup_syntax = function() end
  end
  M.setup_autocmds(M.config)
end

local function printv(msg, verbose)
  if istrue(verbose) ~= false then print(msg) end
end

local function check_empty(list, num_items, verbose)
  if num_items == 0 then
    if list == 'c' then
      printv("Quickfix list empty", verbose)
      return false
    else
      printv("Location list empty", verbose)
      return false
    end
  end
  return true
end

-- Close and opens list if already open.
-- This is to fix the list stretching bottom of a new vertical split.
function M.reopen(list)
  local prev = fn.win_getid(fn.winnr('#'))
  if api.nvim_buf_get_option(api.nvim_win_get_buf(0), 'filetype') ~= 'qf' or
    api.nvim_buf_get_option(api.nvim_win_get_buf(prev), 'filetype') ~= 'qf' then
    return
  end

  list = fix_list(list)

  if not utils.get_list_win(list) then
    return
  end

  cmd('noau ' .. list .. 'close | noau ' .. list .. 'open ' .. get_height(list, M.config))

  M.on_ft()

  cmd("noau wincmd p")
end

function M.reopen_all()
  local reopen = M.reopen
  reopen('c')
  reopen('l')
end

local set_list = utils.set_list
local get_list = utils.get_list

local function set_entry(list, idx)
  set_list(list, {}, "r", { idx = idx })
end

-- Setup qf filetype specific options
function M.on_ft(winid)
  winid = winid or fn.win_getid()
  local wininfo = fn.getwininfo(winid) or {}
  local list = nil

  if not wininfo or not wininfo[1] then
    return
  end

  if wininfo[1].quickfix == 1 then
    list = 'c'
  end

  if wininfo[1].loclist == 1 then
    list = 'l'
  end

  if list == nil then
    return
  end

  local opts = M.config[list]

  bo.buflisted = false
  wo.winfixheight = true
  wo.number = opts.number
  wo.relativenumber = opts.relativenumber

  if opts.auto_resize then
    api.nvim_win_set_height(winid, get_height(list, M.config))
  end

  if opts.wide then
    cmd "wincmd J"
  end
end

-- Resize list to the number of items between max and min height
-- If stay, the list will not be focused.
function M.resize(list)
  list = fix_list(list)

  local opts = M.config[list]

  local win = utils.get_list_win(list)

  -- Don't do anything if list isn't open
  if win == 0 then
    return
  end

  local height = get_height(list, M.config)
  if height ~= 0 then
    api.nvim_win_set_height(win, height)
  elseif opts.auto_close() then
    cmd(list .. 'close')
  end
end

--- Open the `quickfix` or `location` list
--- If stay == true, the list will not be focused
--- If auto_close is true, the list will be closed if empty, similar to cwindow
--- @param list string
--- @param stay boolean
function M.open(list, stay, silent)
  list = fix_list(list)

  local opts = M.config[list]
  local num_items = #list_items(list)

  -- Auto close
  if num_items == 0 then
    if silent ~= true then
      api.nvim_err_writeln("No items")
    end
    if opts.auto_close then
      cmd(list .. 'close')
      return
    end
    return
  end

  if M.config.close_other then
    if list == 'c' then
      cmd 'lclose'
    elseif list == 'l' then
      cmd 'cclose'
    end
  end

  local win = utils.get_list_win(list)
  if win ~= 0 then
    if not istrue(stay) then
      api.nvim_set_current_win(win)
    end
    return
  end
  cmd(list .. 'open ' .. get_height(list, M.config))

  if istrue(stay) then
    cmd "wincmd p"
  end
end

--- Close list
function M.close(list)
  list = fix_list(list)

  cmd(list .. 'close')
end

-- Toggle list
-- If stay == true, the list will not be focused
--- @param list string
--- @param stay boolean
function M.toggle(list, stay)
  list = fix_list(list)

  if utils.get_list_win(list) ~= 0 then
    M.close(list)
  else
    M.open(list, stay)
  end

end

--- Clears the quickfix or current location list
--- If name is not nil, the current list will be saved before being cleared
--- @param list string
--- @param name string
function M.clear(list, name)
  list = fix_list(list)

  if name then
    M.save(list, name)
  end

  if list == 'c' then
    fn.setqflist({})
  else
    fn.setloclist('.', {})
  end

  M.open(list, 0)
end

local function clear_prompt()
  vim.api.nvim_command('normal :esc<CR>')
end

local is_valid = utils.is_valid

-- Returns the list entry currently previous to the cursor
local function follow_prev(items, bufnr, line)
  local last_valid = 1
  for i=1,#items do
    local j = #items - i + 1
    local item = items[j]

    if is_valid(item) and item.bufnr == bufnr then
      last_valid = j
      if item.lnum <= line then
        return j
      end
    end
  end

  return last_valid
end

-- Returns the list entry currently after the cursor
local function follow_next(items, bufnr, line)
  local i = 1
  local last_valid = 1
  for _,item in ipairs(items) do
    if is_valid(item) and item.bufnr == bufnr then
      last_valid = i
      if item.lnum >= line then
        return i
      end
    end

    i = i + 1
  end

  return last_valid
end

-- Returns the list entry closest to the cursor vertically
local function follow_nearest(items, bufnr, line)
  local i = 1
  local min = nil
  local min_i = nil

  for _,item in ipairs(items) do
    if is_valid(item) then
      local dist = math.abs(item.lnum - line)

      if min == nil or dist < min and item.bufnr == bufnr then
        min = dist
        min_i = i
      end
    end

    i = i + 1
  end

  return min_i
end


local strategy_lookup = {
  prev = follow_prev,
  next = follow_next,
  nearest = follow_nearest,
}

--- strategy is one of the following:
--- - 'prev'
--- - 'next'
--- - 'nearest'
--- (optional) limit, don't select entry further away than limit.
--- If entry is further away than limit, the entry will not be selected. This is to prevent recentering of cursor caused by setpos. There is no way to select an entry without jumping, so the cursor position is saved and restored instead.
function M.follow(list, strategy, limit)
  if api.nvim_get_mode().mode ~= 'n' then
    return
  end

  list = fix_list(list)
  local opts = M.config[list]

  local pos = fn.getpos('.')

  local bufnr = fn.bufnr('%')
  local line = pos[2]

  -- Cursor hasn't moved to a new line since last call
  if opts.last_line and opts.last_line == line then
    return
  end

  opts.last_line = line

  local strategy_func = strategy_lookup[strategy or 'prev']
  if strategy_func == nil then
    api.nvim_err_writeln("Invalid follow strategy " .. strategy)
    return
  end

  local items = list_items(list)

  if #items == 0 then
    return
  end

  local i = strategy_func(items, bufnr, line)

  if i == nil or items[i].bufnr ~= bufnr then
    return
  end

  if type(limit == 'boolean') and limit == true then
    limit = opts.auto_follow_limit
  end

  if limit and math.abs(items[i].lnum - line) > limit then
    return
  end

  -- Clear echo area
  clear_prompt()
  -- Select found entry
  set_entry(list, i)
end

-- Wrapping version of [lc]next. Also takes into account valid entries.
-- If wrap is nil or true, it will wrap around the list
function M.next(list, wrap, verbose)
  if wrap == nil then
    wrap = true
  end
  list = fix_list(list)

  if not check_empty(list, #list_items(list), verbose) then
    return
  end

  if wrap then
    cmd ("try | :" .. list .. "next | catch | " .. list .. "first | endtry")
  else
    cmd ("try | :" .. list .. "next | catch | call nvim_err_writeln('No More Items') | endtry")
  end
end

-- Wrapping version of [lc]prev. Also takes into account valid entries.
-- If wrap is nil or true, it will wrap around the list
function M.prev(list, wrap, verbose)
  if wrap == nil then
    wrap = true
  end
  list = fix_list(list)

  if not check_empty(list, #list_items(list), verbose) then
    return
  end

  if wrap then
    cmd ("try | :" .. list .. "prev | catch | " .. list .. "last | endtry")
  else
    cmd ("try | :" .. list .. "prev | catch | call nvim_err_writeln('No More Items') | endtry")
  end
end


local function prev_valid(items, idx)
  while idx and idx > 1 do
    idx = idx - 1
    if is_valid(items[idx]) then
      return idx
    end
  end

  return idx
end

local function prev_valid_wrap(items, start)
  for i=1,#items do
    local idx = (#items + start - i - 1) % #items + 1
    if is_valid(items[idx]) then
      return idx
    end
  end
  return 1
end

local function next_valid_wrap(items, start)
  for i=1,#items do
    local idx = (i + start - 1) % #items + 1
    if is_valid(items[idx]) then
      return idx
    end
  end
  return 1
end

local function next_valid(items, idx)
  while idx and idx <= #items - 1 do
    idx = idx + 1
    if is_valid(items[idx]) then
      return idx
    end
  end

  api.nvim_err_writeln("No more items")
  return nil
end

-- Wrapping version of [lc]above
-- Will switch buffer
function M.above(list, wrap, verbose)
  if wrap == nil then
    wrap = true
  end

  list = fix_list(list)

  local items = list_items(list, true)

  if not check_empty(list, #items, verbose) then
    return
  end

  local bufnr = fn.bufnr('%')
  local line = fn.line('.')

  local idx = follow_next(items, bufnr, line)

  -- Go to last valid entry
  if wrap then
    idx = prev_valid_wrap(items, idx)
  else
    idx = prev_valid(items, idx)
  end

  -- No valid entries, go to first.
  if idx == 0 then
    idx = 1
  end

  if list == 'c' then
    cmd('cc ' .. idx)
  else
    cmd('ll ' .. idx)
  end
end

-- Wrapping version of [lc]below
-- Will switch buffer
function M.below(list, wrap, verbose)
  if wrap == nil then
    wrap = true
  end
  list = fix_list(list)

  local items = list_items(list, true)

  if not check_empty(list, #items, verbose) then
    return
  end

  local bufnr = fn.bufnr('%')
  local line = fn.line('.')

  local idx = follow_prev(items, bufnr, line)

  -- Go to first valid entry
  if wrap then
    idx = next_valid_wrap(items, idx)
  else
    idx = next_valid(items, idx)
  end

  if list == 'c' then
    cmd('cc ' .. idx)
  else
    cmd('ll ' .. idx)
  end
end

-- Save quickfix or location list with name
function M.save(list, name)
  list = fix_list(list)

  M.saved[name] = list_items(list)
end

local function prompt_name()
  local t = {}
  for k,_ in pairs(M.saved) do
    t[#t+1] = k
  end

  if #t == 0 then
    api.nvim_err_writeln("No saved lists")
  end

  local choice = fn.confirm('Choose saved list', table.concat(t, '\n'))
  if choice == nil then
    return nil
  end

  return t[choice]
end

-- Loads a saved list into the location or quickfix list
-- If name is not given, user will be prompted with all saved lists.
function M.load(list, name)
  list = fix_list(list)

  if name == nil then
    name = prompt_name()
  end

  if name == nil then
    return
  end

  local items = M.saved[name]

  if items == nil then
    api.nvim_err_writeln("No list saved with name: " .. name)
    return
  end

  if list == 'c' then
    fn.setqflist(items)
  else
    fn.setloclist('.', items)
  end

  if M.config[list].auto_open then
    M.open(list, true)
  end
end

--- @class set_opts
--- @field items table
--- @field lines table
--- @field cwd string
--- @field compiler string|nil
--- @field winid number|nil
--- @field title string|nil
--- @field tally boolean|nil
--- @field open boolean

--- Set location or quickfix list items
--- If a compiler is given, the items will be parsed from it
--- Invalidates follow cache
--- @param list string
--- @param opts set_opts
function M.set(list, opts)
  list = fix_list(list)

  local old_c = vim.b.current_compiler;

  local old_efm = vim.opt.efm

  local old_makeprg = vim.o.makeprg
  local old_cwd = fn.getcwd()

  if opts.cwd then
    api.nvim_set_current_dir(opts.cwd)
  end

  if opts.compiler ~= nil then
    vim.cmd("compiler! " .. opts.compiler)
  else
  end
  if opts.lines == nil and opts.items == nil then
    api.nvim_err_writeln("Missing either opts.lines or opts.items in qf.set()")
  end

  if list == 'c' then
    vim.fn.setqflist({}, 'r', {
      title = opts.title,
      items = opts.items,
      lines = opts.lines
    })
  else
    vim.fn.setloclist(opts.winid or 0, {}, 'r', {
      title = opts.title,
      items = opts.items,
      lines = opts.lines,
    })
  end

  vim.b.current_compiler = old_c
  vim.opt.efm = old_efm
  vim.o.makeprg = old_makeprg
  if old_c ~= nil then
    vim.cmd("compiler " .. old_c)
  end

  if opts.tally then
    M.tally(list, opts.title or "")
  end

  M.config[list].last_line = nil

  if opts.cwd then
    api.nvim_set_current_dir(old_cwd)
  end

  if opts.open ~= false then
    M.open(list, true, true)
  else
    M.close(list)
  end
end

--- Suffix the chosen list with a summary of the classified number of entries
function M.tally(list, title)
  list = fix_list(list)

  if title == nil then
    title = get_list(list, { title = 1 }).title
  end

  local s = title:match("[^%-]*") .. utils.tally(list)

  set_list(list, {}, "r", { title = s})
end

--- @class Filter
--- @field type string|nil
--- @field text string|nil

--- Filter and keep items in a list based on predicate
--- @param list string
--- @param filter Filter
function M.keep(list, filter)
  list = fix_list(list);
  local items = vim.tbl_filter(function(v)
    return
      (filter.type == nil or filter.type == v.type) and
      (filter.text == nil or v.text:find(filter.text))
  end, list_items(list))

  M.set(list, { items = items, open = true})
end

function M.sort(list)
  list = fix_list(list)
  local items = list_items(list, true)
  table.sort(items, function(a, b)
    a.fname = a.fname or fn.bufname(a.bufnr)
    b.fname = b.fname or fn.bufname(b.bufnr)

    if not is_valid(a) then
      a.text = "invalid"
    end
    if not is_valid(b) then
      b.text = "invalid"
    end

    if a.fname == b.fname then
      if a.lnum == b.lnum then
        return a.col < b.col
      else
        return a.lnum < b.lnum
      end
    else
      return a.fname < b.fname
    end
  end)

  M.set(list, {
    items = items,
  })
end

--- Setup and configure qf.nvim
--- @param config config
function M.setup_autocmds(config)
  local g = api.nvim_create_augroup("qf", { clear = true })
  local au = function(events, callback, opts)
    opts = opts or {}
    opts.group = g
    opts.callback = callback
    api.nvim_create_autocmd(events, opts)
  end

  local follow = M.follow
  local open = M.open
  local close = M.close
  for k,list in pairs({ c = config.c, l = config.l }) do
    if list.auto_follow then
      au(list.follow_slow and "CursorHold" or "CursorMoved", function() follow(k, list.auto_follow, true) end)
    end

    if list.unfocus_close then
      au("WinLeave", function() vim.defer_fn(function() close(k) end, 50) end)
    end

    if list.focus_open then
      au("WinEnter",  function() open(k, true) end)
    end

    if list.auto_open then
      au("QuickFixCmdPost", function() open(k, true, true) end, { pattern = list_post_commands(k) })
    end
  end
end

return M
