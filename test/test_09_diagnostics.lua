local h = require('helpers')

local SET = [[
  local buf, items = ...
  local ns = vim.api.nvim_create_namespace('test')
  vim.diagnostic.set(ns, buf, items)
]]

return {
  {
    'diagnostics: snapshot has buffers with diagnostics',
    function()
      local n = h.nvim()
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, { 'a', 'b' })
      n:lua(SET, buf, { { lnum = 1, col = 0, severity = 1, message = 'bad', source = 'test' } })
      local s = n:attach({ 'diagnostics' }).snapshot.diagnostics
      h.eq(1, #s.buffers)
      local d = s.buffers[1].diagnostics[1]
      h.eq({ 1, 1, 'bad', 'test' }, { d.lnum, d.severity, d.message, d.source })
    end,
  },
  {
    'diagnostics: changes are sent as the full list, batched',
    function()
      local n = h.nvim()
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, { 'a', 'b', 'c' })
      n:attach({ 'diagnostics' })
      for i = 0, 2 do
        local items = {}
        for j = 0, i do
          items[#items + 1] = { lnum = j, col = 0, severity = 2, message = 'w' .. j }
        end
        n:lua(SET, buf, items)
      end
      local ev = n:wait_for(function(e)
        return e.domain == 'diagnostics' and #e.diagnostics == 3
      end)
      h.ok(ev, vim.inspect(n:events('diagnostics')))
      h.ok(#n:events('diagnostics') <= 2, 'not batched: ' .. #n:events('diagnostics'))
    end,
  },
}
