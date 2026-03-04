-- dsl.lua (ascii only)
-- Provides: loadModesDslOrStop(path)

local util = require("relayctl.util")

local M = {}

local function stripComments(line)
  local a = line:find("//", 1, true)
  local b = line:find("#", 1, true)
  local cut = nil
  if a and b then cut = math.min(a, b) else cut = a or b end
  if cut then line = line:sub(1, cut - 1) end
  return line
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function tokenizeExpr(s)
  local t = {}
  local i = 1
  local n = #s
  local function add(kind, val) table.insert(t, { kind = kind, val = val }) end

  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "(" or c == ")" then
      add(c, c); i = i + 1
    elseif s:sub(i, i+1) == "==" or s:sub(i, i+1) == "!=" or s:sub(i, i+1) == ">=" or s:sub(i, i+1) == "<=" then
      add("op", s:sub(i, i+1)); i = i + 2
    elseif c == ">" or c == "<" then
      add("op", c); i = i + 1
    elseif s:sub(i, i+1) == ".." then
      add("dots", ".."); i = i + 2
    elseif c:match("[%d]") then
      local j = i
      while j <= n and s:sub(j, j):match("[%d]") do j = j + 1 end
      add("num", tonumber(s:sub(i, j-1))); i = j
    elseif c:match("[%a_]") then
      local j = i
      while j <= n and s:sub(j, j):match("[%w_]") do j = j + 1 end
      local w = s:sub(i, j-1)
      local lw = w:lower()
      if lw == "and" or lw == "or" or lw == "in" or lw == "true" or lw == "false" then
        add(lw, lw)
      else
        add("id", w)
      end
      i = j
    else
      add("bad", c); i = i + 1
    end
  end
  add("eof", "eof")
  return t
end

local function parseExprToAst(tokens)
  local pos = 1
  local function cur() return tokens[pos] end
  local function eat(kind, val)
    local c = cur()
    if c.kind == kind and (val == nil or c.val == val) then
      pos = pos + 1
      return c
    end
    return nil
  end
  local function expect(kind, val, err)
    local c = eat(kind, val)
    if not c then error(err or ("Expected " .. tostring(kind))) end
    return c
  end

  local function parseValue()
    local c = cur()
    if eat("num") then return { kind="value", vtype="num", value=c.val } end
    if eat("true") then return { kind="value", vtype="bool", value=true } end
    if eat("false") then return { kind="value", vtype="bool", value=false } end
    error("Expected value (number/true/false)")
  end

  local function parseComparison()
    local left = cur()
    if not eat("id") then error("Expected identifier") end
    local name = left.val

    if eat("in") then
      local a = expect("num", nil, "Expected number after 'in'").val
      expect("dots", "..", "Expected '..' in range")
      local b = expect("num", nil, "Expected number after '..'").val
      return { kind="range", name=name, min=a, max=b }
    end

    local opTok = expect("op", nil, "Expected operator (== != > >= < <=)")
    local valAst = parseValue()
    return { kind="cmp", name=name, op=opTok.val, value=valAst }
  end

  local function parsePrimary()
    if eat("(") then
      local function parseAnd()
        local node = parsePrimary()
        while eat("and") do
          local rhs = parsePrimary()
          node = { kind="and", a=node, b=rhs }
        end
        return node
      end
      local function parseOr()
        local node = parseAnd()
        while eat("or") do
          local rhs = parseAnd()
          node = { kind="or", a=node, b=rhs }
        end
        return node
      end
      local e = parseOr()
      expect(")", ")", "Expected ')'")
      return e
    end
    return parseComparison()
  end

  local function parseAnd()
    local node = parsePrimary()
    while eat("and") do
      local rhs = parsePrimary()
      node = { kind="and", a=node, b=rhs }
    end
    return node
  end

  local function parseOr()
    local node = parseAnd()
    while eat("or") do
      local rhs = parseAnd()
      node = { kind="or", a=node, b=rhs }
    end
    return node
  end

  local ast = parseOr()
  if cur().kind ~= "eof" then error("Unexpected token after expression") end
  return ast
end

local function astToEngineCond(ast)
  local function isBoolVal(v) return type(v)=="table" and v.vtype=="bool" end
  local function isNumVal(v) return type(v)=="table" and v.vtype=="num" end

  local function leafFromCmp(name, op, valAst)
    if name:lower() == "time_passed" then
      if not isNumVal(valAst) then error("time_passed must compare to a number") end
      return { time_passed = valAst.value, op = op }
    end
    if isBoolVal(valAst) then return { redstone_links = name, signal = valAst.value, op = op } end
    if isNumVal(valAst) then return { redstone_links = name, signal = valAst.value, op = op } end
    error("Bad comparison value")
  end

  local function leafFromRange(name, minv, maxv)
    if name:lower() == "time_passed" then error("time_passed cannot be used with 'in'") end
    return { redstone_links = name, signal = { min=minv, max=maxv }, op = "in" }
  end

  local function rec(node)
    if node.kind == "and" then
      return { if_and = { rec(node.a), rec(node.b) } }
    elseif node.kind == "or" then
      return { if_or = { rec(node.a), rec(node.b) } }
    elseif node.kind == "cmp" then
      return leafFromCmp(node.name, node.op, node.value)
    elseif node.kind == "range" then
      return leafFromRange(node.name, node.min, node.max)
    else
      error("Unknown AST node kind: " .. tostring(node.kind))
    end
  end

  return rec(ast)
end

local function parseQuoted(s)
  s = trim(s)
  if s:sub(1,1) ~= '"' then return nil end
  local out = {}
  local i = 2
  while i <= #s do
    local c = s:sub(i,i)
    if c == '"' then
      return table.concat(out), s:sub(i+1)
    end
    table.insert(out, c)
    i = i + 1
  end
  return nil
end

local function parseModesDsl(text)
  local lines = {}
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, raw) end

  local cfg = { default_mode = "stop", all_modes = {} }
  local i = 1
  local function err(msg) error("DSL error on line " .. tostring(i) .. ": " .. msg) end

  local function nextNonEmpty()
    while i <= #lines do
      local l = trim(stripComments(lines[i]))
      if l ~= "" then return l end
      i = i + 1
    end
    return nil
  end

  local function parseDefaultMode(l)
    local m = l:match("^default_mode%s+([%w_]+)%s*$")
    if not m then err("Expected: default_mode <id>") end
    cfg.default_mode = m
  end

  local function parseModeHeader(l)
    local rest = trim(l:sub(5))
    local name, tail = parseQuoted(rest)
    if not name then err('Mode name must be quoted: mode "..."') end
    tail = trim(tail or "")
    local seq = tail:match("^sequence%s+(.+)$")
    if not seq then err("Expected: sequence <infinite|single|number>") end
    seq = trim(seq)

    local seqMode
    if seq == "infinite" or seq == "single" then
      seqMode = seq
    else
      local n = tonumber(seq)
      if not n then err("sequence must be infinite, single, or a number") end
      seqMode = n
    end
    return { mode_name = name, sequence_mode = seqMode, sequence = {} }
  end

  local function parseActionHeader(l)
    local id = l:match("^action%s+([%w_]+)%s+")
    if not id then err('Expected: action <id> "Display Name"') end
    local rest = trim(l:gsub("^action%s+[ %w_]+%s+", ""))
    local disp = parseQuoted(rest)
    if not disp then err('Action display name must be quoted: action id "Name"') end
    return { action = id, action_name = disp, action_initialization = {}, goto_rules = {} }
  end

  local function parseInitLine(l, action)
    local link, rhs = l:match("^init%s+([%w_]+)%s*=%s*(.+)$")
    if not link then err("Bad init syntax. Expected: init <link> = <value>") end
    rhs = trim(rhs)
    local v
    if rhs == "true" then v = true
    elseif rhs == "false" then v = false
    else
      local n = tonumber(rhs)
      if not n then err("Init value must be true/false/number") end
      v = n
    end
    table.insert(action.action_initialization, { redstone_links = link, signal = v })
  end

  local function gatherIfExpression(firstLine)
    local expr = trim(firstLine or "")
    if expr ~= "" then return expr end

    local parts = {}
    while true do
      i = i + 1
      if i > #lines then break end
      local l = trim(stripComments(lines[i]))
      if l ~= "" then
        local kw = l:match("^([%w_]+)")
        if kw == "init" or kw == "goto" or kw == "end" or kw == "action" or kw == "endmode" or kw == "mode" or kw == "default_mode" then
          i = i - 1
          break
        end
        table.insert(parts, l)
      end
    end
    return table.concat(parts, " ")
  end

  local function parseGotoLine(l, action)
    local target = l:match("^goto%s+([%w_]+)%s+")
    if not target then err("Bad goto syntax. Expected: goto <actionId> after <sec> if <expr>") end

    local afterStr = l:match("^goto%s+[%w_]+%s+after%s+([%d]+)%s+")
    if not afterStr then err("goto must include: after <seconds>") end
    local waiting = tonumber(afterStr) or 0

    local ifPart = l:match("%sif%s*(.*)$")
    if ifPart == nil then err("goto must include: if <expression>") end

    local expr = trim(gatherIfExpression(ifPart))
    if expr == "" then err("Empty if expression") end

    local tokens = tokenizeExpr(expr)
    local okAst, astOrErr = pcall(parseExprToAst, tokens)
    if not okAst then err("Expression parse failed: " .. tostring(astOrErr)) end

    local okCond, condOrErr = pcall(astToEngineCond, astOrErr)
    if not okCond then err("Expression build failed: " .. tostring(condOrErr)) end

    table.insert(action.goto_rules, {
      goto_action = target,
      waiting_time = waiting,
      cond = condOrErr
    })
  end

  while true do
    local l = nextNonEmpty()
    if not l then break end

    if l:match("^default_mode%s+") then
      parseDefaultMode(l)
      i = i + 1

    elseif l:match("^mode%s+") then
      local mode = parseModeHeader(l)
      i = i + 1

      while true do
        local inner = nextNonEmpty()
        if not inner then err("Unexpected EOF inside mode") end

        if inner == "endmode" then
          table.insert(cfg.all_modes, mode)
          i = i + 1
          break
        elseif inner:match("^action%s+") then
          local action = parseActionHeader(inner)
          i = i + 1

          while true do
            local al = nextNonEmpty()
            if not al then err("Unexpected EOF inside action") end

            if al == "end" then
              table.insert(mode.sequence, action)
              i = i + 1
              break
            elseif al:match("^init%s+") then
              parseInitLine(al, action)
              i = i + 1
            elseif al:match("^goto%s+") then
              parseGotoLine(al, action)
              i = i + 1
            else
              err("Unknown line inside action: " .. al)
            end
          end
        else
          err("Unknown line inside mode: " .. inner)
        end
      end

    else
      err("Unknown top-level line: " .. l)
    end
  end

  return cfg
end

function M.loadModesDslOrStop(path)
  if not util.fileExists(path) then
    return { default_mode = "stop", all_modes = {} }, "cfg_modes.dsl not found"
  end
  local s = util.readAll(path)
  if not s then
    return { default_mode = "stop", all_modes = {} }, "failed reading cfg_modes.dsl"
  end
  local ok, cfgOrErr = pcall(parseModesDsl, s)
  if not ok then
    return { default_mode = "stop", all_modes = {} }, tostring(cfgOrErr)
  end
  return cfgOrErr, nil
end

return M