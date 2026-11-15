-- <Tab> completes the path at the cursor from a popup on the input caret that
-- narrows as you type. Words opening with `@`, `$` or `!` are left to their
-- own completers, and <Tab> falls through when there is no word to complete.
-- A word with no matching path gets a notice instead, since <Tab>'s default
-- switches between plan and build, which a typo should not do.
local ListPicker = require("maki.list_picker")

local FOOTER = { { "Tab/Enter", "insert" }, { "↑/↓", "move" }, { "Esc", "close" } }
local MAX_ITEMS = 10
-- Above the input box and the transcript, below anything modal.
local ZINDEX = 120
local BORDER = 2
local PAD = 2
local NO_MATCHES = "No matching paths"
local TITLE = "Path completion"
local SHELL_SPECIALS = "([%s\\'\"`$;&|<>()%[%]{}*?!#])"
-- What a backslash escapes inside double quotes; before anything else it is a
-- literal backslash, as in a shell.
local DQUOTE_ESCAPES = '([\\"$`])'

-- `{ win, buf, sel, items, more, start, quote, st, root, listing }`: `start`
-- is the byte offset the word opens at, `st` the newest input snapshot it was
-- ranked for, `more` how many matches did not fit, and `listing` the entries
-- of the directory last read, keyed by its path.
local popup = nil

-- The word ending at {text}'s end, unquoted and unescaped, the byte offset it
-- starts at, and the quote still open in it.
local function token_before(text)
  local start, quote, escaped = 1, nil, false
  local value = {}
  for i = 1, #text do
    local char = text:sub(i, i)
    if escaped then
      value[#value + 1] = char
      escaped = false
    elseif char == "\\" and not quote then
      escaped = true
    elseif char == "\\" and quote == '"' and text:sub(i + 1, i + 1):match(DQUOTE_ESCAPES) then
      escaped = true
    elseif quote then
      if char == quote then
        quote = nil
      else
        value[#value + 1] = char
      end
    elseif char == "'" or char == '"' then
      quote = char
    elseif char:match("%s") then
      start = i + 1
      value = {}
    else
      value[#value + 1] = char
    end
  end
  return start - 1, table.concat(value), quote
end

local function encode(path, quote)
  if quote == "'" then
    return "'" .. path:gsub("'", "'\\''")
  elseif quote == '"' then
    return '"' .. path:gsub(DQUOTE_ESCAPES, "\\%1")
  end
  return (path:gsub(SHELL_SPECIALS, "\\%1"))
end

-- The word at {st}'s cursor, or nil when it is not one this plugin completes.
local function word_at(st)
  if not st or st.anchor or st.text:sub(st.cursor + 1, st.cursor + 1):match("%S") then
    return nil
  end
  local start, token, quote = token_before(st.text:sub(1, st.cursor))
  if token == "" or token:match("^[@$!]") then
    return nil
  end
  return start, token, quote
end

local function session_root()
  local session = maki.session.read()
  return session and session.cwd or "."
end

-- {token} split at its last slash, and the directory that part names.
local function locate(token, root)
  local directory, needle = token:match("^(.*/)([^/]*)$")
  directory, needle = directory or "", needle or token
  local lookup = directory
  if lookup == "" then
    lookup = root
  elseif lookup:sub(1, 2) == "~/" then
    lookup = maki.fs.joinpath(maki.uv.os_homedir(), lookup:sub(3))
  elseif lookup:sub(1, 1) ~= "/" then
    lookup = maki.fs.joinpath(root, lookup)
  end
  return directory, needle, lookup
end

-- The names in {lookup}, directories ending in a slash. Reuses {listing} while
-- it is for the same directory, so narrowing does not read it on every key.
local function list(lookup, listing)
  if listing and listing.lookup == lookup then
    return listing
  end
  local names = {}
  for _, entry in ipairs(maki.fs.dir(lookup) or {}) do
    names[#names + 1] = entry[1] .. (entry[2] == "directory" and "/" or "")
  end
  return { lookup = lookup, names = names }
end

-- Entries of the directory {token} names, fuzzy-ranked on its last segment,
-- with how many were cut and the listing they came from. Dotfiles show only
-- once that segment starts with a dot.
local function matches(token, root, listing)
  local directory, needle, lookup = locate(token, root)
  listing = list(lookup, listing)
  local items = {}
  local lowered = needle:lower()
  for _, name in ipairs(listing.names) do
    if needle:sub(1, 1) == "." or name:sub(1, 1) ~= "." then
      local score, highlights = maki.text.fuzzy(needle, name, { paths = true })
      if score then
        items[#items + 1] = {
          name = name,
          path = directory .. name,
          score = score,
          highlights = highlights,
          prefix = name:sub(1, #needle):lower() == lowered,
        }
      end
    end
  end
  table.sort(items, function(a, b)
    if a.score == b.score then
      return a.path < b.path
    end
    return a.score > b.score
  end)
  local more = math.max(#items - MAX_ITEMS, 0)
  for _ = 1, more do
    table.remove(items)
  end
  return items, more, listing
end

local BINDINGS

-- A buffer's bindings keep it alive while their handlers refer to it, so they
-- go with the window.
local function close()
  local closing = popup
  popup = nil
  if closing then
    for _, binding in ipairs(BINDINGS) do
      maki.keymap.del("i", binding.lhs, { buffer = closing.buf })
    end
    closing.win:close()
  end
end

-- A file ends the word, closing any quote left open; a directory leaves the
-- caret, and the quote, in it to keep going. Returns the input after the edit.
local function insert(st, start, quote, path)
  local text = encode(path, quote)
  if path:sub(-1) ~= "/" then
    text = text .. (quote or "") .. " "
  end
  local edited, err = maki.ui.input_edit({
    start = start,
    stop = st.cursor,
    text = text,
    version = st.version,
    session_id = st.session_id,
  })
  if not edited then
    maki.notify(tostring(err), "error", { title = TITLE })
    return nil
  end
  return {
    text = st.text:sub(1, start) .. text .. st.text:sub(st.cursor + 1),
    cursor = edited.cursor or start + #text,
    version = edited.version,
    session_id = st.session_id,
  }
end

local open

-- With nothing to insert, <CR> still sends the message.
local function accept(ev, lhs)
  local current = popup
  local choice = current and current.items[current.sel]
  close()
  if not choice then
    return lhs == "<CR>" and ev and ev.fallback()
  end
  local after = insert(current.st, current.start, current.quote, choice.path)
  if after and choice.path:sub(-1) == "/" then
    local _, token, quote = word_at(after)
    if token then
      local items, more, listing = matches(token, current.root)
      if #items > 0 then
        open(after, current.start, quote, items, more, current.root, listing)
      end
    end
  end
end

local function lines()
  if #popup.items == 0 then
    return { { { " " .. NO_MATCHES, "dim" } } }
  end
  local out = {}
  for i, item in ipairs(popup.items) do
    local selected = i == popup.sel
    local base = selected and "selected" or "item"
    out[i] = ListPicker.range_spans(item.name, item.highlights, base, selected and "match_selected" or "match")
    table.insert(out[i], 1, { " ", base })
  end
  if popup.more > 0 then
    out[#out + 1] = { { " +" .. popup.more .. " more", "dim" } }
  end
  return out
end

local function render()
  local rows = lines()
  local width = maki.ui.display_width(NO_MATCHES)
  for _, item in ipairs(popup.items) do
    width = math.max(width, maki.ui.display_width(item.name))
  end
  popup.buf:set_lines(rows)
  popup.win:set_config({
    width = math.min(width + PAD + BORDER, maki.ui.terminal_size().cols),
    height = #rows + BORDER,
  })
end

local function move(delta)
  local count = #popup.items
  if count > 0 then
    popup.sel = (popup.sel - 1 + delta) % count + 1
    popup.buf:set_lines(lines())
  end
end

BINDINGS = {
  { lhs = "<Tab>", run = accept, desc = "Insert path" },
  { lhs = "<CR>", run = accept, desc = "Insert path" },
  { lhs = "<Down>", run = function() move(1) end, desc = "Next path" },
  { lhs = "<Up>", run = function() move(-1) end, desc = "Previous path" },
  { lhs = "<C-n>", run = function() move(1) end, desc = "Next path" },
  { lhs = "<C-p>", run = function() move(-1) end, desc = "Previous path" },
  { lhs = "<Esc>", run = close, desc = "Close path completion" },
}

-- Keys bound to the popup's buffer fire only while it is on screen, before any
-- global binding, so closing the window hands them all back.
function open(st, start, quote, items, more, root, listing)
  local buf = maki.ui.buf()
  local win = maki.ui.open_win(buf, {
    width = PAD + BORDER,
    height = BORDER + 1,
    anchor = "input_caret",
    border = "rounded",
    footer = FOOTER,
    zindex = ZINDEX,
    focus = false,
  })
  local mine = {
    win = win,
    buf = buf,
    sel = 1,
    items = items,
    more = more,
    start = start,
    quote = quote,
    st = st,
    root = root,
    listing = listing,
  }
  popup = mine
  for _, binding in ipairs(BINDINGS) do
    maki.keymap.set("i", binding.lhs, function(ev)
      if popup == mine then
        binding.run(ev, binding.lhs)
      end
    end, { buffer = buf, desc = binding.desc })
  end
  render()
end

local function narrow(st)
  if not popup then
    return
  end
  local start, token, quote = word_at(st)
  if not start or st.session_id ~= popup.st.session_id or start ~= popup.start then
    return close()
  end
  popup.st, popup.quote, popup.sel = st, quote, 1
  popup.items, popup.more, popup.listing = matches(token, popup.root, popup.listing)
  render()
end

maki.keymap.set("i", "<Tab>", function(ev)
  if maki.ui.action("completion.accept") then
    return
  end
  local st = ev.input
  local start, token, quote = word_at(st)
  if not start then
    return ev.fallback()
  end
  local root = session_root()
  local items, more, listing = matches(token, root)
  if #items == 0 then
    maki.notify(NO_MATCHES, "info", { title = TITLE })
  elseif #items == 1 and items[1].prefix then
    insert(st, start, quote, items[1].path)
  else
    open(st, start, quote, items, more, root, listing)
  end
end, { desc = "Complete file path or accept completion" })

maki.api.create_autocmd("InputChanged", {
  callback = function(ev)
    narrow(ev.data)
  end,
})

for _, event in ipairs({ "SessionReset", "TaskFocusChanged" }) do
  maki.api.create_autocmd(event, { callback = close })
end

maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(ev)
    if ev.data.focused and ev.data.status == "needs_input" then
      close()
    end
  end,
})

-- Pure helpers, exposed for tests.
return { token_before = token_before, encode = encode }
