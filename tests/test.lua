local api = vim.api
local repo = vim.fn.getcwd()
vim.opt.rtp:prepend(repo)
vim.cmd('runtime plugin/readtrail.lua')
vim.cmd('filetype plugin indent on')
vim.o.hidden = true

local trace = require('readtrail')
local dir = assert(vim.env.READTRAIL_TEST_DIR)
local project = dir .. '/project'
vim.fn.mkdir(project .. '/.git', 'p')
vim.cmd.cd(project)

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end

local function write(name, lines)
  vim.fn.writefile(lines, project .. '/' .. name)
end

local function edit(name)
  vim.cmd.edit(vim.fn.fnameescape(project .. '/' .. name))
end

local function contains(text, part)
  assert(text:find(part, 1, true), 'Missing: ' .. part .. '\n' .. text)
end

write('a.ts', { '// Existing library documentation.', 'const parser = compile(grammar)', 'use(parser)' })
write('b.lua', { 'local result = execute(input)', 'return result' })
edit('a.ts')
trace.add()
vim.cmd.stopinsert()
equal(api.nvim_buf_get_lines(0, 0, -1, false), {
  '// @trace[001] ', '', '// Existing library documentation.', 'const parser = compile(grammar)', 'use(parser)',
})
api.nvim_buf_set_lines(0, 0, 1, false, {
  '// @trace[001] Is this only construction?', '// Where does execution happen?', '//', '// Still unsure.',
})
vim.cmd.write()
local a = api.nvim_get_current_buf()

edit('b.lua')
trace.add()
vim.cmd.stopinsert()
api.nvim_buf_set_lines(0, 0, 1, false, { '-- @trace[002] Execution is here.' })
local b = api.nvim_get_current_buf()
local report = table.concat(trace.export(), '\n')
contains(report, '## [001] a.ts')
contains(report, '## [002] b.lua')
contains(report, 'Target: line 7')
contains(report, 'Where does execution happen?\n\nStill unsure.')
contains(report, 'Source: unsaved buffer')
contains(report, '7 | const parser = compile(grammar)')
assert(report:find('[001]', 1, true) < report:find('[002]', 1, true))

local default_prompt = trace.prompt
trace.prompt = 'Check my assumptions.\n\nAsk one question at a time.'
report = table.concat(trace.export(), '\n')
contains(report, trace.prompt)
assert(not report:find(default_prompt, 1, true))
assert(report:find(trace.prompt, 1, true) < report:find('## [001]', 1, true))
trace.prompt = ''
report = table.concat(trace.export(), '\n')
contains(report, '## [001] a.ts')
assert(not report:find(default_prompt, 1, true))
trace.prompt = default_prompt

-- A second thought at the same point follows all continuation lines.
api.nvim_set_current_buf(a)
api.nvim_win_set_cursor(0, { 2, 0 })
trace.add()
vim.cmd.stopinsert()
equal(api.nvim_buf_get_lines(0, 4, 5, false), { '// @trace[003] ' })
vim.cmd.write()
api.nvim_set_current_buf(b)
vim.cmd.write()
api.nvim_buf_delete(a, {})
report = table.concat(trace.export(), '\n')
contains(report, '## [003] a.ts') -- Collect a closed file from disk.
assert(report:find('[002]', 1, true) < report:find('[003]', 1, true))

-- A malformed marker blocks cleanup without deleting anything.
api.nvim_buf_set_lines(b, 0, 0, false, { '-- @trace[broken] test' })
local before = api.nvim_buf_get_lines(b, 0, -1, false)
local ok, err = pcall(trace.clear)
assert(not ok and tostring(err):find('Malformed trace'))
equal(api.nvim_buf_get_lines(b, 0, -1, false), before)
api.nvim_buf_set_lines(b, 0, 1, false, {})

-- Duplicate numbers are not silently ordered or deleted.
api.nvim_buf_set_lines(b, 0, 0, false, { '-- @trace[001] duplicate' })
ok, err = pcall(trace.export)
assert(not ok and tostring(err):find('Duplicate trace'))
api.nvim_buf_set_lines(b, 0, 1, false, {})

-- Cleanup checks every file before changing any of them.
edit('a.ts')
a = api.nvim_get_current_buf()
vim.bo[a].readonly = true
before = api.nvim_buf_get_lines(b, 0, -1, false)
ok, err = pcall(trace.clear)
assert(not ok and tostring(err):find('read%-only'))
equal(api.nvim_buf_get_lines(b, 0, -1, false), before)
vim.bo[a].readonly = false

-- Clear preserves ordinary comments and unrelated edits, and saves a snapshot.
api.nvim_buf_set_lines(b, -1, -1, false, { '-- Unrelated edit.' })
local snapshot = trace.clear()
contains(table.concat(vim.fn.readfile(snapshot), '\n'), 'Execution is here.')
equal(api.nvim_buf_get_lines(a, 0, -1, false), {
  '', '// Existing library documentation.', 'const parser = compile(grammar)', 'use(parser)',
})
equal(api.nvim_buf_get_lines(b, 0, -1, false), {
  'local result = execute(input)', 'return result', '-- Unrelated edit.',
})
assert(vim.bo[a].modified and vim.bo[b].modified)
contains(table.concat(vim.fn.readfile(project .. '/a.ts'), '\n'), '@trace[001]')
vim.cmd.wall()

-- Saved cleanup resets numbering.
api.nvim_win_set_cursor(0, { 3, 0 })
trace.add()
vim.cmd.stopinsert()
contains(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n'), '@trace[001]')
vim.cmd.write()

print('PASS: insertion, multiline notes, ordered export, custom prompt, cleanup, and counter reset')
