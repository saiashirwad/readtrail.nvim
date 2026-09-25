local M = {}
local api = vim.api

M.context_lines = 4
M.prompt = [[Read the whole trace before answering. Account for later corrections.
Verify my understanding against the repository. Distinguish remaining
questions from ones I appear to have answered. Refer to trace numbers.]]

local function root()
  return vim.b.readtrail_root
    or vim.fs.root(api.nvim_buf_get_name(0), '.git')
    or vim.fn.getcwd()
end

local function state_path(project)
  local dir = vim.fn.stdpath('state') .. '/readtrail'
  vim.fn.mkdir(dir, 'p')
  return dir .. '/' .. vim.fn.sha256(project)
end

local function read_state(project)
  local path = state_path(project) .. '.json'
  if vim.fn.filereadable(path) == 0 then
    return { next = 1, files = {} }
  end
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

local function save_state(project, state)
  local path = state_path(project) .. '.json'
  vim.fn.writefile({ vim.json.encode(state) }, path .. '.tmp')
  assert(vim.uv.fs_rename(path .. '.tmp', path))
end

local function comment_prefix()
  local before, after = vim.bo.commentstring:match('^(.-)%%s(.-)$')
  assert(before and vim.trim(before) ~= '' and vim.trim(after) == '',
    'Trace requires a line-comment commentstring, such as // %s or -- %s')
  return vim.trim(before)
end

local function comment_text(line, prefix)
  return line:match('^%s*' .. vim.pesc(prefix) .. ' ?(.*)$')
end

local function parse(lines, prefix)
  local notes, current = {}, nil
  for row, line in ipairs(lines) do
    local body = comment_text(line, prefix)
    if body and body:match('^@trace%[') then
      local id, text = body:match('^@trace%[(%d+)%] ?(.*)$')
      assert(id and tonumber(id) > 0, 'Malformed trace at line ' .. row)
      current = { id = tonumber(id), first = row, last = row, text = { text } }
      notes[#notes + 1] = current
    elseif body and current then
      current.last = row
      current.text[#current.text + 1] = body
    else
      current = nil
    end
  end
  for _, note in ipairs(notes) do
    local target = note.last + 1
    while target <= #lines and (lines[target]:match('^%s*$') or comment_text(lines[target], prefix)) do
      target = target + 1
    end
    note.target = target <= #lines and target or nil
  end
  return notes
end

local function read_file(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    return api.nvim_buf_get_lines(buf, 0, -1, false), buf
  end
  assert(vim.fn.filereadable(path) == 1, 'Cannot read annotated file: ' .. path)
  return vim.fn.readfile(path), nil
end

local function collect(state)
  local notes, files, seen = {}, {}, {}
  for path, prefix in pairs(state.files) do
    local lines, buf = read_file(path)
    local ok, parsed = pcall(parse, lines, prefix)
    assert(ok, path .. ': ' .. tostring(parsed))
    local file = { path = path, lines = lines, buf = buf, notes = parsed }
    files[#files + 1] = file
    for _, note in ipairs(parsed) do
      assert(not seen[note.id], 'Duplicate trace number: ' .. note.id)
      seen[note.id] = true
      note.file = file
      notes[#notes + 1] = note
    end
  end
  table.sort(notes, function(a, b) return a.id < b.id end)
  table.sort(files, function(a, b) return a.path < b.path end)
  return notes, files
end

function M.add()
  assert(vim.bo.buftype == '' and vim.bo.modifiable, 'Trace requires an editable file buffer')
  local path = api.nvim_buf_get_name(0)
  assert(path ~= '', 'Give this buffer a file name before adding a trace')
  local prefix = comment_prefix()
  local project = root()
  local state = read_state(project)
  state.files[path] = prefix
  local notes = collect(state)
  local id = math.max(state.next, #notes > 0 and notes[#notes].id + 1 or 1)
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local row = api.nvim_win_get_cursor(0)[1]
  local parsed = parse(lines, prefix)
  -- Inside a trace, append after its entire thought. On its target, append
  -- before the code, naturally following any earlier thoughts at that point.
  for _, note in ipairs(parsed) do
    if row >= note.first and row <= note.last then
      row = note.last + 1
      break
    end
  end
  local indent = (lines[row] or lines[row - 1] or ''):match('^%s*')
  local inserted = { indent .. prefix .. string.format(' @trace[%03d] ', id) }
  local following = lines[row] and comment_text(lines[row], prefix)
  if following and not following:match('^@trace%[') then
    inserted[#inserted + 1] = ''
  end
  -- Persist first so a write failure cannot leave an unregistered annotation.
  state.next = id + 1
  save_state(project, state)
  api.nvim_buf_set_lines(0, row - 1, row - 1, false, inserted)
  vim.opt_local.formatoptions:append('r')
  api.nvim_win_set_cursor(0, { row, #inserted[1] })
  vim.cmd.startinsert({ bang = true })
end

local function relative(path, project)
  local prefix = project:gsub('/$', '') .. '/'
  return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
end

local function render(project, notes)
  local out = {
    '# Reading trace',
    '',
    'Project: ' .. project,
    'Order: annotation creation order, across files.',
    'Locations: current annotated file/buffer coordinates (before cleanup).',
    '',
  }
  if M.prompt ~= '' then
    vim.list_extend(out, vim.split(M.prompt, '\n', { plain = true }))
    out[#out + 1] = ''
  end
  for _, note in ipairs(notes) do
    local file = note.file
    vim.list_extend(out, {
      string.format('## [%03d] %s', note.id, relative(file.path, project)),
      '',
      'Annotation: lines ' .. note.first .. '-' .. note.last,
      'Target: ' .. (note.target and ('line ' .. note.target) or 'no following code'),
      'Source: ' .. (file.buf and vim.bo[file.buf].modified and 'unsaved buffer' or 'file'),
      '',
    })
    vim.list_extend(out, note.text)
    out[#out + 1] = ''
    if note.target then
      -- An indented Markdown code block also handles source containing fences.
      for row = note.target, math.min(#file.lines, note.target + M.context_lines - 1) do
        out[#out + 1] = string.format('    %d | %s', row, file.lines[row])
      end
      out[#out + 1] = ''
    end
  end
  return out
end

function M.export()
  local project = root()
  local notes = collect(read_state(project))
  assert(#notes > 0, 'No traces in this project')
  return render(project, notes)
end

function M.show()
  local project = root()
  local lines = M.export()
  vim.cmd('botright vnew')
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.bo.swapfile = false
  vim.b.readtrail_root = project
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = 'markdown'
  vim.bo.modifiable = false
end

function M.copy()
  local lines = M.export()
  assert(vim.fn.has('clipboard') == 1, 'No clipboard provider. Use :TraceExport to view the trace')
  vim.fn.setreg('+', table.concat(lines, '\n') .. '\n', 'v')
  vim.notify('Reading trace copied to clipboard')
end

function M.clear()
  local project = root()
  local state = read_state(project)
  local notes, files = collect(state)
  assert(#notes > 0, 'No traces in this project')
  -- Load and check every affected buffer before removing anything.
  for _, file in ipairs(files) do
    if #file.notes > 0 then
      file.buf = file.buf or vim.fn.bufadd(file.path)
      vim.fn.bufload(file.buf)
      assert(vim.bo[file.buf].modifiable and not vim.bo[file.buf].readonly,
        'Cannot clear read-only buffer: ' .. file.path)
      assert(vim.deep_equal(file.lines, api.nvim_buf_get_lines(file.buf, 0, -1, false)),
        'Buffer changed while loading; run TraceClear again: ' .. file.path)
    end
  end
  local snapshot = state_path(project) .. '-last-export.md'
  vim.fn.writefile(render(project, notes), snapshot)
  local changed = 0
  for _, file in ipairs(files) do
    if #file.notes > 0 then
      for i = #file.notes, 1, -1 do
        local note = file.notes[i]
        if i < #file.notes then
          api.nvim_buf_call(file.buf, function() vim.cmd.undojoin() end)
        end
        api.nvim_buf_set_lines(file.buf, note.first - 1, note.last, false, {})
      end
      changed = changed + 1
    end
  end
  state.next = 1
  -- Keep the file list: discarded/undone cleanup must be rediscovered on restart.
  save_state(project, state)
  vim.notify(string.format('Cleared %d traces in %d buffers. Save the buffers to keep the removal.\nSnapshot: %s',
    #notes, changed, snapshot))
  return snapshot
end

return M
