local api = vim.api
local fn = vim.fn

local async = require("hover.async")

--- @param bufnr integer
--- @return string cwd, string fname
local function get_file_parts(bufnr)
	local file = api.nvim_buf_get_name(bufnr)
	return fn.fnamemodify(file, ":p:h"), fn.fnamemodify(file, ":t")
end

--- @param bufnr integer
--- @param opts? Hover.Options
--- @return boolean
local function enabled(bufnr, opts)
	local file = api.nvim_buf_get_name(bufnr)
	if file == "" then
		return false
	end
	local cwd = fn.fnamemodify(file, ":p:h")
	local result = vim.system({ "git", "rev-parse", "--git-dir" }, { cwd = cwd }):wait()
	return result.code == 0
end

--- @param cmd string[]
--- @param opts vim.SystemOpts?
--- @param cb fun(out: vim.SystemCompleted)
local function system(cmd, opts, cb)
	vim.system(cmd, opts, cb)
end

--- @param params Hover.Provider.Params
--- @param done fun(result?: false|Hover.Provider.Result)
local function execute(params, done)
	async.run(function()
		local bufnr = params.bufnr
		local lnum = params.pos[1] -- 1-indexed

		local file = api.nvim_buf_get_name(bufnr)
		if file == "" then
			done(false)
			return
		end

		local cwd, fname = get_file_parts(bufnr)

		-- git blame --porcelain -L lnum,lnum <fname>
		local blame = async.await(3, system, {
			"git",
			"blame",
			"--porcelain",
			"-L",
			lnum .. "," .. lnum,
			fname,
		}, { cwd = cwd })

		if blame.code ~= 0 or not blame.stdout then
			done(false)
			return
		end

		local hash = blame.stdout:match("^(%x+)")
		if not hash or hash:match("^0+$") then
			-- uncommitted line
			done(false)
			return
		end

		-- git show --format="%an\n%ad\n\n%s\n\n%b" --no-patch <hash>
		local show = async.await(3, system, {
			"git",
			"show",
			"--format=%an%n%ad%n%n%s%n%n%b",
			"--date=short",
			"--no-patch",
			hash,
		}, { cwd = cwd })

		if show.code ~= 0 then
			done(false)
			return
		end

		local stdout = vim.trim(show.stdout or "")
		local parts = vim.split(stdout, "\n", { plain = true })

		local author = parts[1] or ""
		local date = parts[2] or ""
		-- parts[3] is blank separator
		local rest = vim.trim(table.concat(parts, "\n", 4))

		local short_hash = hash:sub(1, 8)
		local lines = {
			"Commit  " .. "**" .. short_hash .. "**",
			"Author  " .. "**" .. author .. "**",
			"Date    " .. "**" .. date .. "**",
			"------",
		}
		for _, line in ipairs(vim.split(rest, "\n")) do
			lines[#lines + 1] = line
		end

		done({ lines = lines, filetype = "markdown" })
	end)
end

--- @type Hover.Provider
return {
	name = "Commit Message",
	priority = 100,
	enabled = enabled,
	execute = execute,
}
