-- Directories for the GUI's Directories mode: the start dirs to pick from, and switching
-- Neovim's cwd to one of them (the git domain follows the cwd).
local M = {}

local function norm(p)
  return vim.fs.normalize(vim.fn.expand(p))
end

local function is_dir(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == 'directory'
end

--- Dirs of the recent files (v:oldfiles), most recent first, without duplicates.
local function recent(max)
  local seen, list = {}, {}
  for _, f in ipairs(vim.v.oldfiles or {}) do
    if not f:match('^%a+://') then
      local d = norm(vim.fs.dirname(f))
      local key = d:lower()
      if not seen[key] and is_dir(d) then
        seen[key] = true
        list[#list + 1] = d
        if #list >= max then
          break
        end
      end
    end
  end
  return list
end

--- { source = 'startdirs' | 'oldfiles', dirs = { path, ... } }: genja-startdirs' ranked list
--- (frecency, like its Telescope picker) when the plugin is there, else recent files' dirs.
function M.list()
  local ok, sd = pcall(require, 'genja-startdirs')
  if ok and type(sd) == 'table' and type(sd.ranked) == 'function' then
    local ok2, ranked = pcall(sd.ranked)
    if ok2 and type(ranked) == 'table' then
      local list = {}
      for _, p in ipairs(ranked) do
        list[#list + 1] = norm(p)
      end
      return { source = 'startdirs', dirs = list }
    end
  end
  return { source = 'oldfiles', dirs = recent(100) }
end

--- :cd to `path`; returns the new cwd. Doesn't count as a use for genja-startdirs.
function M.set(path)
  local p = norm(path)
  if not is_dir(p) then
    error('nvimos: not a directory: ' .. p)
  end
  vim.cmd.cd(vim.fn.fnameescape(p))
  return vim.fs.normalize(vim.fn.getcwd())
end

--- Root of this plugin (the dir with lua/nvimos), so the GUI can start another Neovim with it.
function M.plugin_root()
  local f = vim.api.nvim_get_runtime_file('lua/nvimos/init.lua', false)[1]
  return f and vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(f)))) or vim.NIL
end

return M
