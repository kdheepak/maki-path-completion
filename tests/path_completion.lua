local SESSION = "s1"
local ROOT = "/repo"
local NO_MATCHES = "No matching paths"

local DIRS = {
  [ROOT] = { { "src", "directory" }, { "scripts", "directory" }, { "README.md", "file" }, { ".git", "directory" } },
  [ROOT .. "/src/"] = { { "main.rs", "file" }, { "my file.rs", "file" }, { "lib.rs", "file" } },
  [ROOT .. "/scripts/"] = { { "build.sh", "file" } },
  [ROOT .. "/many/"] = {},
}
for i = 1, 12 do
  table.insert(DIRS[ROOT .. "/many/"], { string.format("f%02d", i), "file" })
end

local tab, autocmds, edits, notices, wins, fell_back, reads, current
local actions = {}
local function reset()
  edits, notices, wins, fell_back, reads = {}, {}, {}, false, 0
end
reset()

local function input(text, cursor)
  return { text = text, cursor = cursor or #text, version = 1, session_id = SESSION }
end

maki = {
  notify = function(msg, level, opts)
    notices[#notices + 1] = { msg = msg, level = level, title = opts and opts.title }
  end,
  keymap = {
    set = function(mode, lhs, fn, opts)
      if opts.buffer then
        opts.buffer.keys[lhs] = fn
      elseif lhs == "<Tab>" then
        tab = fn
      end
    end,
    del = function(mode, lhs, opts)
      opts.buffer.keys[lhs] = nil
    end,
  },
  api = {
    register_action = function(name, fn, opts)
      actions[name] = { run = fn, capability = opts and opts.capability }
      return "maki-path-completion." .. name
    end,
    create_autocmd = function(event, spec)
      autocmds = autocmds or {}
      autocmds[event] = spec.callback
    end,
  },
  ui = {
    action = function() return false end,
    input = function() return current end,
    input_edit = function(edit)
      edits[#edits + 1] = edit
      return { version = edit.version + 1, cursor = edit.start + #edit.text }
    end,
    buf = function()
      return { keys = {}, set_lines = function(self, value) self.lines = value end }
    end,
    open_win = function(buf)
      local win = { buf = buf, open = true }
      function win:close() self.open = false end
      function win:set_config() end
      wins[#wins + 1] = win
      return win
    end,
    display_width = function(text) return #text end,
    terminal_size = function() return { cols = 80, rows = 24 } end,
  },
  session = { read = function() return { cwd = ROOT } end },
  fs = {
    dir = function(path)
      reads = reads + 1
      return DIRS[path]
    end,
    joinpath = function(a, b) return a .. "/" .. b end,
  },
  uv = { os_homedir = function() return "/home" end },
  text = {
    fuzzy = function(needle, name)
      local at = name:find(needle, 1, true)
      if needle == "" then
        return 0, {}
      end
      return at and 100 - at, at and { { at, at + #needle - 1 } }
    end,
  },
}
package.loaded["maki.list_picker"] = {
  range_spans = function(label, _, base) return { { label, base } } end,
}
local MODULE = arg[1] or "lua/maki_path_completion.lua"
local M = dofile(MODULE)
M.setup()
M.setup()

local function fallback()
  fell_back = true
end

local function press(st)
  tab({ input = st, fallback = fallback })
end

local function popup_win()
  local win = wins[#wins]
  return win and win.open and win
end

local count = 0
local function test(name, fn)
  reset()
  fn()
  if popup_win() then
    popup_win().buf.keys["<Esc>"]()
  end
  count = count + 1
  print("ok " .. count .. " - " .. name)
end

test("falls back on mentions and empty words", function()
  press(input("see @src"))
  assert(fell_back)
  fell_back = false
  press(input("see "))
  assert(fell_back)
end)

test("inserts the only match with a trailing space", function()
  press(input("open src/ma"))
  assert(#wins == 0)
  assert(edits[1].start == 5 and edits[1].stop == 11)
  assert(edits[1].text == "src/main.rs ")
end)

test("leaves the caret inside a completed directory", function()
  press(input("cd sr"))
  assert(edits[1].text == "src/")
end)

test("escapes shell specials and closes an open quote after a file", function()
  press(input("cat src/my"))
  assert(edits[1].text == "src/my\\ file.rs ")
  press(input("cat 'src/my"))
  assert(edits[2].text == "'src/my file.rs' ")
  press(input('cat "src/my'))
  assert(edits[3].text == '"src/my file.rs" ')
end)

test("keeps an open quote open after a directory", function()
  press(input("cd 'sr"))
  assert(edits[1].text == "'src/")
end)

test("opens a popup instead of inserting a lone fuzzy match", function()
  press(input("cat src/ain"))
  local win = popup_win()
  assert(#edits == 0)
  assert(win and #win.buf.lines == 1)
end)

test("hides dotfiles unless asked", function()
  press(input("ls .g"))
  assert(edits[1].text == ".git/")
end)

test("notifies when nothing matches", function()
  press(input("cat zzz"))
  assert(notices[1].msg == NO_MATCHES and notices[1].title == "Path completion")
  assert(not fell_back and #edits == 0 and #wins == 0)
end)

test("opens a popup, moves, and accepts the selection", function()
  press(input("cat src/"))
  local win = popup_win()
  assert(win and #win.buf.lines == 3)
  win.buf.keys["<Down>"]()
  local second = win.buf.lines[2][2][1]
  assert(not second:find("/", 1, true))
  win.buf.keys["<Tab>"]()
  assert(not win.open)
  assert(edits[1].text == "src/" .. second .. " ")
end)

test("frees the popup's key bindings when it closes", function()
  press(input("cat src/"))
  local win = popup_win()
  win.buf.keys["<Esc>"]()
  assert(not win.open and next(win.buf.keys) == nil)
end)

test("reopens on the contents of an accepted directory", function()
  press(input("cd s"))
  local first = popup_win()
  first.buf.keys["<Tab>"]()
  assert(not first.open and edits[1].text == "scripts/")
  local second = popup_win()
  assert(second and second ~= first)
  assert(second.buf.lines[1][2][1] == "build.sh")
  second.buf.keys["<Tab>"]()
  assert(edits[2].text == "scripts/build.sh " and edits[2].version == 2)
end)

test("submits on Enter when nothing matches", function()
  press(input("cat src/"))
  local win = popup_win()
  autocmds.InputChanged({ data = input("cat src/zz") })
  win.buf.keys["<CR>"]({ fallback = fallback })
  assert(fell_back and not win.open and #edits == 0)
end)

test("closes without falling back on Tab when nothing matches", function()
  press(input("cat src/"))
  local win = popup_win()
  autocmds.InputChanged({ data = input("cat src/zz") })
  win.buf.keys["<Tab>"]({ fallback = fallback })
  assert(not fell_back and not win.open)
end)

test("says how many matches did not fit", function()
  press(input("cat many/"))
  local lines = popup_win().buf.lines
  assert(#lines == 11)
  assert(lines[11][1][1] == " +2 more")
end)

test("reads a directory once while narrowing within it", function()
  press(input("cat src/"))
  autocmds.InputChanged({ data = input("cat src/l") })
  autocmds.InputChanged({ data = input("cat src/li") })
  assert(reads == 1)
end)

test("closes on a missing snapshot", function()
  press(input("cat src/"))
  local win = popup_win()
  autocmds.InputChanged({ data = nil })
  assert(not win.open)
end)

test("parses quotes the way a shell does", function()
  for _, case in ipairs({
    { [[cat a\ b]], 4, "a b", nil },
    { [[cat "a\b]], 4, [[a\b]], '"' },
    { [[cat "a\"b]], 4, [[a"b]], '"' },
    { [[cat "a\\b]], 4, [[a\b]], '"' },
    { [[cat 'a\b]], 4, [[a\b]], "'" },
    { [[cat 'it'\''s]], 4, "it's", "'" },
  }) do
    local start, token, quote = M.token_before(case[1])
    assert(start == case[2] and token == case[3] and quote == case[4], case[1])
  end
end)

test("encodes paths that parse back unchanged", function()
  for _, path in ipairs({ "plain", "my file", [[a\b]], [[a"b$c`d]], "it's" }) do
    for _, quote in ipairs({ false, "'", '"' }) do
      local _, token = M.token_before(M.encode(path, quote or nil))
      assert(token == path, path)
    end
  end
end)

test("narrows as the word grows and closes when it is left", function()
  press(input("cat src/"))
  local win = popup_win()
  autocmds.InputChanged({ data = input("cat src/li") })
  assert(#win.buf.lines == 1)
  autocmds.InputChanged({ data = input("cat src/lizz") })
  assert(win.buf.lines[1][1][1]:find(NO_MATCHES, 1, true))
  autocmds.InputChanged({ data = input("cat src/li ") })
  assert(not win.open)
end)

test("closes when another session takes focus", function()
  press(input("cat src/"))
  local win = popup_win()
  local other = input("cat src/l")
  other.session_id = "s2"
  autocmds.InputChanged({ data = other })
  assert(not win.open)
end)

test("registers a complete action that needs what inserting a path takes", function()
  local action = actions.complete
  assert(action)
  table.sort(action.capability)
  assert(table.concat(action.capability, ",") == "agent,fs_read,input,session_read,session_write")
  current = input("open src/ma")
  assert(action.run() == true)
  assert(edits[1].text == "src/main.rs ")
  current = input("see ")
  assert(action.run() == false)
  current = nil
  assert(action.run() == false)
  current = input("cat zzz")
  assert(action.run() == true and notices[1].msg == NO_MATCHES)
end)

test("binds no key with key = false, and another key when asked", function()
  local bound = {}
  local set = maki.keymap.set
  maki.keymap.set = function(mode, lhs, fn, opts)
    if not opts.buffer then
      bound[#bound + 1] = lhs
    end
    return set(mode, lhs, fn, opts)
  end
  dofile(MODULE).setup({ key = false })
  assert(#bound == 0)
  dofile(MODULE).setup({ key = "<M-p>" })
  assert(#bound == 1 and bound[1] == "<M-p>")
  maki.keymap.set = set
end)
