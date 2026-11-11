-- Where the repo's planning lives (Backlog.md tasks, OpenSpec changes): the repo itself, or the folder
-- a `.nvimos` file at the repo root names. Several repos may share one planning folder; `project`
-- names this repo there, so the GUI can show only its tasks.
--
--   # .nvimos
--   tracking = ~/es/nvimos-meta     (~, absolute, or relative to the repo root)
--   project = frontend
local repo = require('nvimos.repo')

local M = {}

local cache = {} -- repo root -> { mtime, info }

--- `key = value` lines of a `.nvimos` file; `#` starts a comment line.
function M.parse(lines)
  local out = {}
  for _, line in ipairs(lines) do
    local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
    if k and not line:match('^%s*#') then
      out[k] = v
    end
  end
  return out
end

local function resolve(root, p)
  p = vim.fs.normalize(p) -- expands ~
  if not p:match('^%a:/') and not p:match('^/') then
    p = vim.fs.normalize(vim.fs.joinpath(root, p))
  end
  return p
end

--- { root, repo_root, project, file }: root is the planning folder (the repo root without a
--- `.nvimos`, or when its folder is missing); file is the `.nvimos` path or vim.NIL.
function M.info()
  local root = repo.root()
  local file = root .. '/.nvimos'
  local st = vim.uv.fs_stat(file)
  local hit = cache[root]
  if hit and hit.mtime == (st and st.mtime.sec or 0) then
    return hit.info
  end
  local info = { root = root, repo_root = root, project = vim.NIL, file = vim.NIL }
  if st then
    local cfg = M.parse(vim.fn.readfile(file))
    info.file = file
    info.project = cfg.project or vim.NIL
    if cfg.tracking then
      local dir = resolve(root, cfg.tracking)
      if vim.fn.isdirectory(dir) == 1 then
        info.root = dir
      else
        info.missing = dir
      end
    end
  end
  cache[root] = { mtime = st and st.mtime.sec or 0, info = info }
  return info
end

--- The planning folder.
function M.root()
  return M.info().root
end

--- Absolute, normalized path for a path relative to the planning folder (or already absolute).
function M.path(p)
  return resolve(M.root(), p)
end

return M
