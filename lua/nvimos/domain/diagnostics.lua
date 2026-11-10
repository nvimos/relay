-- diagnostics domain: the full diagnostic list of a buffer whenever it changes (DiagnosticChanged),
-- batched per buffer over THROTTLE_MS so a busy LSP doesn't flood the client.
local core = require('nvimos')
local api = vim.api

local M = {}

local THROTTLE_MS = 100

local group, timer
local dirty = {} -- buf -> true

function M.list(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    out[#out + 1] = {
      lnum = d.lnum, -- 0-based
      col = d.col,
      end_lnum = d.end_lnum or d.lnum,
      end_col = d.end_col or d.col,
      severity = d.severity, -- 1 error, 2 warn, 3 info, 4 hint
      message = d.message,
      source = d.source or vim.NIL,
      code = d.code or vim.NIL,
    }
  end
  return out
end

local function flush()
  if not core.active('diagnostics') then
    return
  end
  local bufs = vim.tbl_keys(dirty)
  dirty = {}
  table.sort(bufs)
  for _, buf in ipairs(bufs) do
    if api.nvim_buf_is_valid(buf) then
      core.emit('diagnostics', 'changed', {
        buf = buf,
        name = api.nvim_buf_get_name(buf),
        diagnostics = M.list(buf),
      })
    end
  end
end

function M.install()
  dirty = {}
  timer = vim.uv.new_timer()
  group = api.nvim_create_augroup('nvimos_diagnostics', { clear = true })
  api.nvim_create_autocmd('DiagnosticChanged', {
    group = group,
    callback = function(a)
      dirty[a.buf] = true
      if not timer:is_active() then
        timer:start(THROTTLE_MS, 0, vim.schedule_wrap(flush))
      end
    end,
  })
end

function M.uninstall()
  api.nvim_del_augroup_by_id(group)
  timer:stop()
  timer:close()
  timer = nil
end

function M.snapshot()
  local list = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local ds = M.list(buf)
    if #ds > 0 then
      list[#list + 1] = { buf = buf, name = api.nvim_buf_get_name(buf), diagnostics = ds }
    end
  end
  return { buffers = list }
end

return M
