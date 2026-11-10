local h = require('helpers')

local function read(path)
  return vim.fn.readfile(path)
end

local function st(n, path)
  for _, f in ipairs(n:lua("return require('nvimos.git').status()").files) do
    if f.path == path then
      return f
    end
  end
end

-- a.txt with two separate changes (lines 1 and 10), so the diff has two hunks.
local function two_hunks()
  local d = h.repo()
  local orig = {}
  for i = 1, 12 do
    orig[i] = 'line ' .. i
  end
  h.write(d .. '/a.txt', orig)
  h.git(d, 'commit', '-q', '-am', 'twelve lines')
  local new = vim.deepcopy(orig)
  new[1] = 'LINE 1'
  new[10] = 'LINE 10'
  h.write(d .. '/a.txt', new)
  return d, orig, new
end

local function hunks(n, staged)
  local f = n:lua("return require('nvimos.git').diff_file(...)", 'a.txt', staged)
  return f and f.hunks or {}
end

local function pick(hk)
  return { old_start = hk.old_start, new_start = hk.new_start }
end

return {
  {
    'git write: stage, unstage and discard a whole file',
    function()
      local d = h.repo()
      h.write(d .. '/a.txt', { 'x' })
      local n = h.nvim({ cwd = d })
      n:lua("return require('nvimos.git').stage(...)", 'a.txt')
      h.eq(true, st(n, 'a.txt').staged)
      n:lua("return require('nvimos.git').unstage(...)", 'a.txt')
      h.eq({ false, true }, { st(n, 'a.txt').staged, st(n, 'a.txt').unstaged })
      n:lua("return require('nvimos.git').discard(...)", 'a.txt')
      h.eq(nil, st(n, 'a.txt'))
      h.eq({ 'one', 'two', 'three', 'four', 'five' }, read(d .. '/a.txt'))
    end,
  },
  {
    'git write: discard deletes an untracked file',
    function()
      local d = h.repo()
      h.write(d .. '/u.txt', { 'u' })
      local n = h.nvim({ cwd = d })
      n:lua("return require('nvimos.git').discard(...)", 'u.txt')
      h.eq(0, vim.fn.filereadable(d .. '/u.txt'))
    end,
  },
  {
    'git write: stage and unstage one hunk',
    function()
      local d = two_hunks()
      local n = h.nvim({ cwd = d })
      local hs = hunks(n, false)
      h.eq(2, #hs)
      n:lua("return require('nvimos.git').stage_hunk(...)", 'a.txt', pick(hs[2]))
      local staged, unstaged = hunks(n, true), hunks(n, false)
      h.eq({ 1, 1 }, { #staged, #unstaged })
      local added = {}
      for _, l in ipairs(staged[1].lines) do
        if l.kind == 'add' then
          added[#added + 1] = l.text .. '@' .. l.new
        end
      end
      h.eq({ 'LINE 10@10' }, added)
      n:lua("return require('nvimos.git').unstage_hunk(...)", 'a.txt', pick(staged[1]))
      h.eq({ 0, 2 }, { #hunks(n, true), #hunks(n, false) })
    end,
  },
  {
    'git write: discard one hunk reloads the open buffer',
    function()
      local d, _, new = two_hunks()
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit a.txt')
      n:lua("return require('nvimos.git').discard_hunk(...)", 'a.txt', pick(hunks(n, false)[1]))
      local want = vim.deepcopy(new)
      want[1] = 'line 1'
      h.eq(want, read(d .. '/a.txt'))
      h.eq(want, n:request('nvim_buf_get_lines', 0, 0, -1, false))
    end,
  },
  {
    'git write: discard refuses a file with unsaved changes in Neovim',
    function()
      local d = two_hunks()
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit a.txt')
      n:request('nvim_buf_set_lines', 0, 0, 1, false, { 'unsaved' })
      local ok, err = pcall(n.lua, n, "return require('nvimos.git').discard(...)", 'a.txt')
      h.ok(not ok and tostring(err):find('unsaved changes'), tostring(err))
    end,
  },
  {
    'git write: a stale hunk is refused',
    function()
      local d = two_hunks()
      local n = h.nvim({ cwd = d })
      local ok, err = pcall(n.lua, n, "return require('nvimos.git').stage_hunk(...)", 'a.txt', { old_start = 99, new_start = 99 })
      h.ok(not ok and tostring(err):find('refresh'), tostring(err))
    end,
  },
  {
    'git write: checkout switches and reloads; refuses with changes',
    function()
      local d = h.repo()
      h.git(d, 'checkout', '-q', '-b', 'other')
      h.write(d .. '/a.txt', { 'other' })
      h.git(d, 'commit', '-q', '-am', 'other')
      h.git(d, 'checkout', '-q', 'main')
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit a.txt')
      n:lua("return require('nvimos.git').checkout(...)", 'other')
      h.eq('other', n:lua("return require('nvimos.git').status()").branch)
      h.eq({ 'other' }, n:request('nvim_buf_get_lines', 0, 0, -1, false))
      h.write(d .. '/a.txt', { 'dirty' })
      local ok, err = pcall(n.lua, n, "return require('nvimos.git').checkout(...)", 'main')
      h.ok(not ok and tostring(err):find('commit or discard'), tostring(err))
    end,
  },
  {
    'git write: commit the index, refuse an empty message',
    function()
      local d = h.repo()
      h.write(d .. '/a.txt', { 'x' })
      local n = h.nvim({ cwd = d })
      n:lua("return require('nvimos.git').stage(...)", 'a.txt')
      local sha = n:lua("return require('nvimos.git').commit(...)", 'change a\n\nbody')
      h.eq(40, #sha)
      h.eq('change a', vim.trim(h.git(d, 'log', '-1', '--format=%s')))
      local ok = pcall(n.lua, n, "return require('nvimos.git').commit(...)", '  ')
      h.eq(false, ok)
    end,
  },
}
