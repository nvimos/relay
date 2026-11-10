-- buffers domain: the buffer list, buffer options, renames, writes.
local core = require('nvimos')
local api = vim.api

local M = {}

local OPTIONS = { 'filetype', 'buftype', 'modifiable', 'readonly', 'fileformat', 'buflisted', 'modified' }
-- Options reported through OptionSet. filetype comes from FileType. 'modified' has no event of its
-- own in Neovim, so it is compared with the last value sent after changes, writes and loads.
local OPTIONSET = { 'buftype', 'modifiable', 'readonly', 'fileformat', 'buflisted' }

local group
local modified = {} -- buf -> last 'modified' value sent

function M.info(buf)
  local o = {}
  for _, name in ipairs(OPTIONS) do
    o[name] = vim.bo[buf][name]
  end
  return {
    buf = buf,
    name = api.nvim_buf_get_name(buf),
    loaded = api.nvim_buf_is_loaded(buf),
    tick = api.nvim_buf_get_changedtick(buf),
    options = o,
  }
end

local function emit(reason, ev)
  core.emit('buffers', reason, ev)
end

local function option(buf, name)
  emit('option_set', { buf = buf, name = name, value = vim.bo[buf][name] })
end

local function check_modified(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local now = vim.bo[buf].modified
  if modified[buf] ~= now then
    modified[buf] = now
    option(buf, 'modified')
  end
end
M.check_modified = check_modified

function M.install()
  modified = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    modified[buf] = vim.bo[buf].modified
  end
  group = api.nvim_create_augroup('nvimos_buffers', { clear = true })
  local function au(events, fn, pattern)
    api.nvim_create_autocmd(events, {
      group = group,
      pattern = pattern,
      callback = function(a)
        fn(a)
      end,
    })
  end
  au('BufNew', function(a)
    emit('added', M.info(a.buf))
  end)
  au({ 'BufReadPost', 'BufNewFile' }, function(a)
    emit('loaded', M.info(a.buf))
  end)
  au('BufUnload', function(a)
    emit('unloaded', { buf = a.buf })
  end)
  au('BufWipeout', function(a)
    modified[a.buf] = nil
    emit('deleted', { buf = a.buf })
  end)
  au('BufFilePost', function(a)
    emit('renamed', { buf = a.buf, name = api.nvim_buf_get_name(a.buf) })
  end)
  au('BufWritePost', function(a)
    emit('written', { buf = a.buf, name = api.nvim_buf_get_name(a.buf), tick = api.nvim_buf_get_changedtick(a.buf) })
  end)
  au({ 'TextChanged', 'TextChangedI', 'TextChangedP', 'BufWritePost', 'BufReadPost', 'BufEnter' }, function(a)
    check_modified(a.buf)
  end)
  au('OptionSet', function()
    check_modified(api.nvim_get_current_buf())
  end, 'modified')
  au('FileType', function(a)
    option(a.buf, 'filetype')
  end)
  au('OptionSet', function(a)
    if vim.v.option_type ~= 'global' then
      option(api.nvim_get_current_buf(), a.match)
    end
  end, OPTIONSET)
end

function M.uninstall()
  api.nvim_del_augroup_by_id(group)
end

function M.snapshot()
  local list = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    list[#list + 1] = M.info(buf)
  end
  return { buffers = list, current = api.nvim_get_current_buf() }
end

return M
