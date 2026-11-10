-- Test runner: `nvim -l test/run.lua [name filter]`.
-- Each test_*.lua returns a list of { name, fn }. Each fn gets a fresh helpers context.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fs.abspath(arg[0]))))
package.path = root .. '/test/?.lua;' .. package.path

local h = require('helpers')
h.root = root
local filter = arg[1]

local files = vim.fn.glob(root .. '/test/test_*.lua', false, true)
table.sort(files)
local failed = 0
for _, file in ipairs(files) do
  local tests = dofile(file)
  for _, t in ipairs(tests) do
    local name, fn = t[1], t[2]
    if not filter or name:find(filter, 1, true) then
      local ok, err = xpcall(fn, debug.traceback)
      h.cleanup()
      if ok then
        print('  ok ' .. name)
      else
        failed = failed + 1
        print('FAIL ' .. name)
        print((tostring(err):gsub('[^\n]+', '     %0')))
      end
    end
  end
end
os.exit(failed > 0 and 1 or 0)
