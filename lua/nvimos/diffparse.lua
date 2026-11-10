-- Parse `git diff` output into files and hunks. Each line carries its old and new line numbers,
-- so a GUI can jump from any diff line to the file.
local M = {}

local function num(s, default)
  if s == nil or s == '' then
    return default
  end
  return tonumber(s)
end

--- Parse unified diff text. keep_raw: keep each file's header lines and each hunk's raw lines
--- (`_header`, `_raw`), needed to build patches for git apply.
function M.parse(text, keep_raw)
  local files = {}
  local file, hunk
  local old_n, new_n = 0, 0
  for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
    if l:sub(1, 11) == 'diff --git ' then
      local a, b = l:match('^diff %-%-git a/(.-) b/(.+)$')
      file = {
        path = b,
        old_path = a,
        status = 'modified',
        binary = false,
        additions = 0,
        deletions = 0,
        hunks = {},
        _header = { l },
      }
      files[#files + 1] = file
      hunk = nil
    elseif file and l:sub(1, 3) == '@@ ' then
      local os_, oc, ns, nc, sec = l:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$')
      hunk = {
        header = l,
        old_start = num(os_, 0),
        old_count = num(oc, 1),
        new_start = num(ns, 0),
        new_count = num(nc, 1),
        section = sec or '',
        lines = {},
        _raw = { l },
      }
      old_n, new_n = hunk.old_start, hunk.new_start
      file.hunks[#file.hunks + 1] = hunk
    elseif file and not hunk then
      file._header[#file._header + 1] = l
      if l:match('^new file mode') then
        file.status = 'added'
      elseif l:match('^deleted file mode') then
        file.status = 'deleted'
      elseif l:match('^rename from ') then
        file.old_path = l:sub(13)
        file.status = 'renamed'
      elseif l:match('^rename to ') then
        file.path = l:sub(11)
      elseif l:match('^Binary files ') or l:match('^GIT binary patch') then
        file.binary = true
      elseif l:match('^%-%-%- a/') then
        file.old_path = l:sub(7)
      elseif l:match('^%+%+%+ b/') then
        file.path = l:sub(7)
      elseif l == '--- /dev/null' then
        file.status = 'added'
      elseif l == '+++ /dev/null' then
        file.status = 'deleted'
      end
    elseif hunk then
      local c = l:sub(1, 1)
      local t = l:sub(2)
      if c == ' ' then
        hunk.lines[#hunk.lines + 1] = { kind = 'context', text = t, old = old_n, new = new_n }
        old_n, new_n = old_n + 1, new_n + 1
      elseif c == '-' then
        hunk.lines[#hunk.lines + 1] = { kind = 'del', text = t, old = old_n }
        old_n = old_n + 1
        file.deletions = file.deletions + 1
      elseif c == '+' then
        hunk.lines[#hunk.lines + 1] = { kind = 'add', text = t, new = new_n }
        new_n = new_n + 1
        file.additions = file.additions + 1
      elseif c == '\\' then
        local last = hunk.lines[#hunk.lines]
        if last then
          last.no_eol = true
        end
      else
        goto continue
      end
      hunk._raw[#hunk._raw + 1] = l
    end
    ::continue::
  end
  if not keep_raw then
    for _, f in ipairs(files) do
      f._header = nil
      for _, hk in ipairs(f.hunks) do
        hk._raw = nil
      end
    end
  end
  return files
end

return M
