if vim.g.loaded_readtrail then
  return
end
vim.g.loaded_readtrail = true

local function run(action)
  return function()
    local ok, err = pcall(require('readtrail')[action])
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end
end

for command, action in pairs({ TraceAdd = 'add', TraceExport = 'show', TraceCopy = 'copy', TraceClear = 'clear' }) do
  vim.api.nvim_create_user_command(command, run(action), {})
end
