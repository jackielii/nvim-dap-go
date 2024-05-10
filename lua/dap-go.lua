local ts = require("dap-go-ts")

local M = {
  last_testname = "",
  last_testpath = "",
  test_buildflags = "",
  last_test_args = {},
}

local default_config = {
  delve = {
    path = "dlv",
    initialize_timeout_sec = 20,
    port = "${port}",
    args = {},
    build_flags = "",
  },
}

local function load_module(module_name)
  local ok, module = pcall(require, module_name)
  assert(ok, string.format("dap-go dependency error: %s not installed", module_name))
  return module
end

local function get_arguments()
  return coroutine.create(function(dap_run_co)
    local args = {}
    vim.ui.input({ prompt = "Args: " }, function(input)
      args = vim.split(input or "", " ")
      coroutine.resume(dap_run_co, args)
    end)
  end)
end

local function getPackageName()
  local dap = load_module("dap")
  local path = vim.fn.input({
    prompt = 'Path to executable: ',
    default = vim.fn.getcwd() .. '/',
    completion = 'file'
  })
  return (path and path ~= "") and path or dap.ABORT
end

local function filtered_pick_process()
  local opts = {}
  vim.ui.input(
    { prompt = "Search by process name (lua pattern), or hit enter to select from the process list: " },
    function(input)
      opts["filter"] = input or ""
    end
  )
  return require("dap.utils").pick_process(opts)
end

local function setup_delve_adapter(dap, config)
  local args = { "dap", "-l", "127.0.0.1:" .. config.delve.port }
  vim.list_extend(args, config.delve.args)

  dap.adapters.go = {
    type = "server",
    port = config.delve.port,
    executable = {
      command = config.delve.path,
      args = args,
    },
    options = {
      initialize_timeout_sec = config.delve.initialize_timeout_sec,
    },
  }
end

local function setup_go_configuration(dap, configs)
  dap.configurations.go = {
    {
      type = "go",
      name = "Debug",
      request = "launch",
      program = "${file}",
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug (Arguments)",
      request = "launch",
      program = "${file}",
      args = get_arguments,
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug Package",
      request = "launch",
      program = "${fileDirname}",
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug Package (input)",
      request = "launch",
      program = getPackageName,
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Attach",
      mode = "local",
      request = "attach",
      processId = filtered_pick_process,
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug test",
      request = "launch",
      mode = "test",
      program = "${file}",
      buildFlags = configs.delve.build_flags,
    },
    {
      type = "go",
      name = "Debug test (go.mod)",
      request = "launch",
      mode = "test",
      program = "./${relativeFileDirname}",
      buildFlags = configs.delve.build_flags,
    },
  }

  if configs == nil or configs.dap_configurations == nil then
    return
  end

  for _, config in ipairs(configs.dap_configurations) do
    if config.type == "go" then
      table.insert(dap.configurations.go, config)
    end
  end
end

function M.setup(opts)
  local config = vim.tbl_deep_extend("force", default_config, opts or {})
  M.test_buildflags = config.delve.build_flags
  local dap = load_module("dap")
  setup_delve_adapter(dap, config)
  setup_go_configuration(dap, config)
end

local function debug_test(testname, testpath, build_flags)
  local dap = load_module("dap")
  dap.run({
    type = "go",
    name = testname,
    request = "launch",
    mode = "test",
    program = testpath,
    args = { "-test.run", "^" .. testname .. "$" },
    buildFlags = build_flags,
  })
end

function M.debug_test()
  local test = ts.closest_test()

  if test.name == "" then
    vim.notify("no test found")
    return false
  end

  M.last_testname = test.name
  M.last_testpath = test.package

  local msg = string.format("starting debug session '%s : %s'...", test.package, test.name)
  vim.notify(msg)
  debug_test(test.name, test.package, M.test_buildflags)

  return true
end

function M.debug_last_test()
  local testname = M.last_testname
  local testpath = M.last_testpath

  if testname == "" then
    vim.notify("no last run test found")
    return false
  end

  local msg = string.format("starting debug session '%s : %s'...", testpath, testname)
  vim.notify(msg)
  debug_test(testname, testpath, M.test_buildflags)

  return true
end

function M.debug_tests_in_file()
  local ft = vim.api.nvim_get_option_value("filetype", { scope = "local" })
  assert(ft == "go", "can only find test in go files, not " .. ft)
  local parser = vim.treesitter.get_parser(0)
  local root = (parser:parse()[1]):root()

  local testnames = {}

  local test_query = vim.treesitter.query.parse(ft, ts.tests_query)
  assert(test_query, "could not parse test query")
  for _, match, _ in test_query:iter_matches(root, 0, 0, 0) do
    for id, node in pairs(match) do
      local capture = test_query.captures[id]
      if capture == "testname" then
        local name = vim.treesitter.get_node_text(node, 0)
        table.insert(testnames, name)
      end
    end
  end

  -- TODO: telescope picker + shortcut to copy test
  require('dap.ui').pick_one(testnames, "Select test: ", function(name) return name end, function(testname)
    local testpath = ts.get_package_name()
    local dap = require('dap')
    debug_test(testname, testpath, M.test_buildflags)

    local label = "Debug test: "
    -- for i, config in ipairs(dap.configurations.go) do
    --   if config.name:sub(1, #label) == label then
    --     table.remove(dap.configurations.go, i)
    --   end
    -- end
    table.insert(dap.configurations.go, 1, {
      type = "go",
      name = label .. testname,
      request = "launch",
      mode = "test",
      program = testpath,
      args = { "-test.run", "^" .. testname .. "$" },
      buildFlags = M.test_buildflags,
    })
    -- require('dap').run({
    --   type = "go",
    --   name = testname,
    --   request = "launch",
    --   mode = "test",
    --   program = pkg,
    --   args = { "-test.run", "^" .. testname .. "$" },
    --   buildFlags = M.test_buildflags,
    -- })
  end)

  return true
end

function M.debug_and_insert_configuration(config)
  local dap = require('dap')
  if dap.configurations.go[1].name == config.name then
    dap.run(dap.configurations.go[1])
    return
  end

  table.insert(dap.configurations.go, 1, {
    type = "go",
    name = config.name,
    request = config.request,
    mode = config.mode,
    program = config.program,
    args = config.args,
    buildFlags = M.test_buildflags,
  })
  dap.run(dap.configurations.go[1])
end

return M
