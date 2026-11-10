local h = require('helpers')

local function reasons(evs)
  local out = {}
  for _, ev in ipairs(evs) do
    out[#out + 1] = ev.reason
  end
  return out
end

local function find(evs, reason, pred)
  for _, ev in ipairs(evs) do
    if ev.reason == reason and (not pred or pred(ev)) then
      return ev
    end
  end
end

return {
  {
    'buffers: snapshot lists buffers with options',
    function()
      local n = h.nvim()
      local r = n:attach({ 'buffers' })
      local s = r.snapshot.buffers
      h.eq(1, #s.buffers)
      h.eq(s.current, s.buffers[1].buf)
      h.eq(true, s.buffers[1].loaded)
      h.eq(false, s.buffers[1].options.modified)
      h.eq('', s.buffers[1].options.buftype)
    end,
  },
  {
    'buffers: editing a file sends added and loaded, with filetype',
    function()
      local d = h.tmpdir()
      h.write(d .. '/x.lua', { 'return 1' })
      local n = h.nvim({ cwd = d })
      n:lua("vim.cmd('filetype on')")
      n:attach({ 'buffers' })
      n:request('nvim_command', 'edit x.lua')
      n:settle()
      local evs = n:events('buffers')
      local added = h.ok(find(evs, 'added'), 'added: ' .. vim.inspect(reasons(evs)))
      h.ok(added.name:find('x.lua$'), added.name)
      h.ok(find(evs, 'loaded'), 'loaded')
      h.ok(find(evs, 'option_set', function(ev)
        return ev.name == 'filetype' and ev.value == 'lua'
      end), 'filetype lua: ' .. vim.inspect(evs))
      h.no_gaps(evs, 0)
    end,
  },
  {
    'buffers: modified, option change, rename, write, wipe',
    function()
      local d = h.tmpdir()
      local n = h.nvim({ cwd = d })
      n:attach({ 'buffers' })
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, { 'hi' })
      n:request('nvim_command', 'setlocal readonly')
      n:request('nvim_command', 'setlocal noreadonly')
      n:request('nvim_command', 'file y.txt')
      n:request('nvim_command', 'write')
      n:request('nvim_command', 'enew')
      n:request('nvim_command', 'bwipeout ' .. buf)
      n:settle()
      local evs = n:events('buffers')
      h.ok(find(evs, 'option_set', function(ev)
        return ev.buf == buf and ev.name == 'modified' and ev.value == true
      end), 'modified true')
      h.ok(find(evs, 'option_set', function(ev)
        return ev.name == 'readonly' and ev.value == true
      end), 'readonly: ' .. vim.inspect(reasons(evs)))
      local ren = h.ok(find(evs, 'renamed'), 'renamed')
      h.ok(ren.name:find('y.txt$'), ren.name)
      h.ok(find(evs, 'written', function(ev)
        return ev.buf == buf
      end), 'written')
      h.ok(find(evs, 'option_set', function(ev)
        return ev.buf == buf and ev.name == 'modified' and ev.value == false
      end), 'modified false')
      h.ok(find(evs, 'deleted', function(ev)
        return ev.buf == buf
      end), 'deleted')
      h.no_gaps(evs, 0)
    end,
  },
}
