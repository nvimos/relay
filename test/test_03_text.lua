local h = require('helpers')

-- The client's model of one buffer: text from get_text, then deltas applied in seq order.
local function apply(lines, ev)
  local out = {}
  for i = 1, ev.first do
    out[#out + 1] = lines[i]
  end
  for _, l in ipairs(ev.lines) do
    out[#out + 1] = l
  end
  for i = ev.old_last + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

local function model(n, buf, text)
  local lines = text.lines
  for _, ev in ipairs(n:events('buffers')) do
    if ev.buf == buf and ev.seq > text.seq and ev.first then
      lines = apply(lines, ev)
    end
  end
  return lines
end

return {
  {
    'text: get_text returns lines, tick and seq',
    function()
      local n = h.nvim()
      n:attach({ 'buffers' })
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, { 'a', 'b' })
      local t = n:lua("return require('nvimos').get_text(...)", buf)
      h.eq({ 'a', 'b' }, t.lines)
      h.eq(true, t.watched)
      h.ok(t.tick > 0 and t.seq > 0, vim.inspect(t))
    end,
  },
  {
    'text: insert, delete and change deltas carry ranges and lines',
    function()
      local n = h.nvim()
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, { 'a', 'b', 'c' })
      n:attach({ 'buffers' })
      n:request('nvim_buf_set_lines', buf, 1, 1, false, { 'new' })
      n:request('nvim_buf_set_lines', buf, 0, 1, false, {})
      n:request('nvim_buf_set_lines', buf, 1, 2, false, { 'B' })
      n:settle()
      local d = {}
      for _, ev in ipairs(n:events('buffers')) do
        if ev.first then
          d[#d + 1] = { ev.reason, ev.first, ev.old_last, ev.new_last, ev.lines }
        end
      end
      h.eq({
        { 'lines_inserted', 1, 1, 2, { 'new' } },
        { 'lines_deleted', 0, 1, 0, {} },
        { 'lines_changed', 1, 2, 2, { 'B' } },
      }, d)
    end,
  },
  {
    'text: deltas rebuild the text after many kinds of edits',
    function()
      local d = h.tmpdir()
      h.write(d .. '/f.txt', { 'alpha', 'beta', 'gamma', 'delta' })
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit f.txt')
      n:attach({ 'buffers' })
      local buf = n:request('nvim_get_current_buf')
      local text = n:lua("return require('nvimos').get_text(...)", buf)
      n:request('nvim_command', 'normal! ggdd')
      n:request('nvim_command', 'normal! Gyyp')
      n:request('nvim_command', '%s/a/A/g')
      n:request('nvim_input', 'ggOtyped<Esc>')
      n:settle()
      n:request('nvim_buf_set_text', buf, 1, 0, 1, 3, { 'x', 'y' })
      n:request('nvim_command', 'normal! u')
      n:request('nvim_command', '2,3join')
      n:request('nvim_command', 'normal! 2>>')
      n:settle(100)
      h.eq(n:request('nvim_buf_get_lines', buf, 0, -1, false), model(n, buf, text))
      h.no_gaps(n:events('buffers'), 0)
    end,
  },
  {
    'text: :edit! sends unloaded and loaded, and deltas continue after it',
    function()
      local d = h.tmpdir()
      h.write(d .. '/f.txt', { 'one' })
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit f.txt')
      n:attach({ 'buffers' })
      h.write(d .. '/f.txt', { 'two' })
      n:request('nvim_command', 'edit!')
      n:settle()
      local seen = {}
      for _, ev in ipairs(n:events('buffers')) do
        seen[#seen + 1] = ev.reason
      end
      h.ok(vim.tbl_contains(seen, 'unloaded') and vim.tbl_contains(seen, 'loaded'), vim.inspect(seen))
      local buf = n:request('nvim_get_current_buf')
      local text = n:lua("return require('nvimos').get_text(...)", buf)
      h.eq({ 'two' }, text.lines)
      n:request('nvim_buf_set_lines', buf, 1, 1, false, { 'three' })
      n:settle()
      h.eq({ 'two', 'three' }, model(n, buf, text))
    end,
  },
  {
    'text: no deltas for scratch buffers',
    function()
      local n = h.nvim()
      n:attach({ 'buffers' })
      local buf = n:request('nvim_create_buf', false, true)
      n:request('nvim_buf_set_lines', buf, 0, -1, false, { 'x' })
      n:settle()
      for _, ev in ipairs(n:events('buffers')) do
        h.ok(not ev.first, 'unexpected delta ' .. vim.inspect(ev))
      end
      h.eq(false, n:lua("return require('nvimos').get_text(...)", buf).watched)
    end,
  },
}
