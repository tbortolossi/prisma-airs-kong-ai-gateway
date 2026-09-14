-- =============================================================================
-- Assertions for the ai-custom-guardrail functions.
--
-- This file contains no copy of the Lua under test. scripts/run-lua-tests.sh
-- extracts airs_verdict and airs_contents from config/kongctl/airs-guardrail.yaml
-- and injects them as the globals scan_verdict (airs-scan), prompt_verdict
-- (airs-prompt-scan) and airs_contents (airs-scan), so these assertions can
-- never drift from the shipped configuration.
--
-- 71 assertions: 32 verdict cases run against both verdict copies, plus 7 on
-- airs_contents. TAP-style output, non-zero exit on any failure.
--
-- `detail` is a TABLE { reason, category, detections } on every path, never a
-- string: it is wired to metrics.block_detail, and the data plane drops a
-- string there with "metric input_block_detail has unexpected type string,
-- expected table" (LAB-VERIFIED 2026-09-14). check() enforces the shape on
-- every verdict case; the named cases pin the values per path.
--
-- Run with: ./scripts/run-lua-tests.sh
-- =============================================================================

-- Stub for the cjson.safe module Kong ships. The verdict function decodes
-- $(resp) when it arrives as a string; this stub makes that branch run for
-- real without a JSON parser. Known strings map to fixtures, anything else
-- returns nil, err, the cjson.safe contract.
local FIXTURES = {
  ['{"action":"allow","category":"benign"}'] = {
    action = "allow", category = "benign",
  },
  ['{"action":"block","category":"malicious","scan_id":"json-42","prompt_detected":{"injection":true}}'] = {
    action = "block", category = "malicious", scan_id = "json-42",
    prompt_detected = { injection = true },
  },
  ['{"action":"allow","category":"timeout"}'] = {
    action = "allow", category = "timeout",
  },
}
package.preload["cjson.safe"] = function()
  return {
    decode = function(s)
      local hit = FIXTURES[s]
      if hit == nil then return nil, "Expected value but found invalid token" end
      return hit
    end,
  }
end

-- Captured so the cjson.safe failure-mode cases below can restore the working
-- stub after each of them and leave later assertions unaffected.
local WORKING_CJSON_SAFE_LOADER = package.preload["cjson.safe"]

local failures = 0
local total = 0

local function report(name, problem)
  total = total + 1
  if problem then
    failures = failures + 1
    print(string.format("not ok %d - %s\n  # %s", total, name, problem))
  else
    print(string.format("ok %d - %s", total, name))
  end
end

local function contains(haystack, needle)
  return string.find(haystack, needle, 1, true) ~= nil
end

-- detail must be exactly { reason = string, category = string,
-- detections = { string... } }: a sequence with no holes, no other keys.
-- Returns a problem string, or nil.
local function detail_shape_problem(detail)
  if type(detail) ~= "table" then
    return "detail is not a table: " .. tostring(detail)
  end
  for key in pairs(detail) do
    if key ~= "reason" and key ~= "category" and key ~= "detections" then
      return "unexpected key in detail: " .. tostring(key)
    end
  end
  if type(detail.reason) ~= "string" then
    return "detail.reason is not a string: " .. tostring(detail.reason)
  elseif type(detail.category) ~= "string" then
    return "detail.category is not a string: " .. tostring(detail.category)
  elseif type(detail.detections) ~= "table" then
    return "detail.detections is not a table: " .. tostring(detail.detections)
  end
  local n = 0
  for key, value in pairs(detail.detections) do
    n = n + 1
    if type(value) ~= "string" then
      return "detection " .. tostring(key) .. " is not a string"
    end
  end
  if n ~= #detail.detections then
    return "detail.detections is not a sequence"
  end
  return nil
end

-- want: { block = bool, message_has = str, message_lacks = { str... },
--         detail = str (exact reason), detail_has = str,
--         category = str, detections = { str... } (exact, in order) }
local function check(name, got, want)
  local problem = nil
  if type(got) ~= "table" then
    problem = "expected a table, got " .. type(got)
  elseif got.block ~= want.block then
    problem = "expected block=" .. tostring(want.block) .. ", got " .. tostring(got.block)
  elseif type(got.block_message) ~= "string" then
    problem = "block_message is not a string: " .. tostring(got.block_message)
  elseif detail_shape_problem(got.detail) then
    problem = detail_shape_problem(got.detail)
  elseif want.message_has and not contains(got.block_message, want.message_has) then
    problem = string.format("expected block_message containing %q, got %q",
      want.message_has, got.block_message)
  elseif want.detail and got.detail.reason ~= want.detail then
    problem = string.format("expected detail.reason %q, got %q", want.detail, got.detail.reason)
  elseif want.detail_has and not contains(got.detail.reason, want.detail_has) then
    problem = string.format("expected detail.reason containing %q, got %q",
      want.detail_has, got.detail.reason)
  elseif want.category and got.detail.category ~= want.category then
    problem = string.format("expected detail.category %q, got %q",
      want.category, got.detail.category)
  elseif want.detections
      and table.concat(got.detail.detections, ",") ~= table.concat(want.detections, ",") then
    problem = string.format("expected detections {%s}, got {%s}",
      table.concat(want.detections, ","), table.concat(got.detail.detections, ","))
  else
    for _, leak in ipairs(want.message_lacks or {}) do
      if contains(got.block_message, leak) then
        problem = string.format("block_message leaks %q: %q", leak, got.block_message)
        break
      end
    end
  end
  report(name, problem)
end

-- pcall-based check for functions that must raise.
local function check_raises(name, fn, ...)
  local ok = pcall(fn, ...)
  report(name, ok and "expected an error, call succeeded" or nil)
end

-- -----------------------------------------------------------------------------
-- Verdict cases. The same list runs against scan_verdict (airs-scan, BOTH) and
-- prompt_verdict (airs-prompt-scan, INPUT): the two copies must be identical.
-- -----------------------------------------------------------------------------
local function verdict_cases(label, verdict)
  local function case(name, input, want)
    check(label .. ": " .. name, verdict(input), want)
  end

  -- Swaps package.preload["cjson.safe"] for `loader` for the duration of one
  -- case, then restores the working FIXTURES-based stub, so cases after this
  -- one still get a real decoder.
  local function case_with_cjson_loader(name, loader, input, want)
    package.preload["cjson.safe"] = loader
    package.loaded["cjson.safe"] = nil
    case(name, input, want)
    package.preload["cjson.safe"] = WORKING_CJSON_SAFE_LOADER
    package.loaded["cjson.safe"] = nil
  end

  -- Fail-closed paths. Each of these is a way the scan can fail to produce a
  -- usable verdict. Every one of them must block, or the guardrail is
  -- bypassable by making Prisma AIRS unavailable.
  case("nil verdict blocks, detail is a table with category unavailable", nil,
    { block = true, detail = "verdict unavailable (fail-closed)",
      category = "unavailable", detections = {} })
  case("empty table blocks", {},
    { block = true, detail_has = "fail-closed", category = "unavailable", detections = {} })
  case("missing action blocks, and the AIRS category is not trusted",
    { category = "benign" },
    { block = true, detail_has = "fail-closed", category = "unavailable", detections = {} })
  case("non-string action blocks", { action = 1 },
    { block = true, detail_has = "fail-closed", category = "unavailable", detections = {} })
  case("category=error blocks despite action=allow",
    { action = "allow", category = "error" },
    { block = true, detail = "scan error (fail-closed)", category = "error", detections = {} })
  case("category=timeout blocks despite action=allow",
    { action = "allow", category = "timeout" },
    { block = true, detail = "scan timeout (fail-closed)", category = "timeout", detections = {} })
  case("category=error does not enumerate detections",
    { action = "allow", category = "error", prompt_detected = { injection = true } },
    { block = true, detail = "scan error (fail-closed)", category = "error", detections = {} })
  case("fail-closed message is generic",
    { action = "allow", category = "timeout", scan_id = "t-1" },
    { block = true, message_has = "Blocked by Prisma AIRS [scan_id=t-1]",
      message_lacks = { "timeout" } })

  -- Allow path. A benign verdict must not block, or the gateway is unusable.
  case("benign allow passes, detail is an empty table", { action = "allow", category = "benign" },
    { block = false, detail = "", category = "", detections = {} })
  case("allow with no detection fired passes (alert-only profile)",
    { action = "allow", category = "benign", prompt_detected = { injection = false } },
    { block = false, detail = "", category = "", detections = {} })
  case("allow with a fired detection still passes with empty detail (alert-only profile)",
    { action = "allow", category = "benign", prompt_detected = { injection = true } },
    { block = false, detail = "", category = "", detections = {} })

  -- Block path, against the documented Prisma AIRS scan response shape.
  case("block returns the generic client message",
    { action = "block", category = "malicious" },
    { block = true, message_has = "Blocked by Prisma AIRS", detail = "malicious",
      category = "malicious", detections = {} })
  case("block carries scan_id for SCM correlation",
    { action = "block", category = "malicious", scan_id = "abc-123" },
    { block = true, message_has = "[scan_id=abc-123]" })
  case("block without scan_id has no bracket",
    { action = "block", category = "malicious" },
    { block = true, message_lacks = { "[" } })
  case("block_message never names the category or the detection",
    { action = "block", category = "malicious", scan_id = "abc-123",
      prompt_detected = { injection = true, dlp = true } },
    { block = true, message_lacks = { "malicious", "injection", "dlp" } })
  case("detail carries the category and the sorted detections",
    { action = "block", category = "malicious",
      prompt_detected = { injection = true, dlp = true } },
    { block = true, detail = "malicious: dlp, injection",
      category = "malicious", detections = { "dlp", "injection" } })
  case("detail merges prompt and response detections, sorted",
    { action = "block", category = "malicious",
      prompt_detected = { url_cats = true },
      response_detected = { db_security = true, ungrounded = true } },
    { block = true, detail = "malicious: db_security, ungrounded, url_cats",
      category = "malicious", detections = { "db_security", "ungrounded", "url_cats" } })
  case("detections that did not fire are not listed",
    { action = "block", category = "malicious",
      prompt_detected = { dlp = false, injection = true } },
    { block = true, detail = "malicious: injection",
      category = "malicious", detections = { "injection" } })
  case("non-table prompt_detected is ignored",
    { action = "block", category = "malicious", prompt_detected = "oops" },
    { block = true, detail = "malicious", category = "malicious", detections = {} })
  case("missing category on block reads unknown",
    { action = "block" },
    { block = true, detail = "unknown", category = "unknown", detections = {} })
  case("action outside allow|block fails closed, keeping the AIRS category",
    { action = "maybe", category = "benign" },
    { block = true, detail = "unexpected action maybe", category = "benign", detections = {} })
  case("unexpected action with fired detections lists them",
    { action = "maybe", category = "benign", prompt_detected = { injection = true } },
    { block = true, detail = "unexpected action maybe: injection",
      category = "benign", detections = { "injection" } })
  case("unexpected action without category reads unknown",
    { action = "maybe" },
    { block = true, detail = "unexpected action maybe", category = "unknown", detections = {} })

  -- String verdicts. Kong documents $(resp) as a string in the OUTPUT phase;
  -- the cjson.safe stub above serves the fixtures.
  case("decoded JSON string allow passes",
    '{"action":"allow","category":"benign"}',
    { block = false, detail = "", category = "", detections = {} })
  case("decoded JSON string block blocks with scan_id",
    '{"action":"block","category":"malicious","scan_id":"json-42","prompt_detected":{"injection":true}}',
    { block = true, message_has = "[scan_id=json-42]", detail = "malicious: injection",
      category = "malicious", detections = { "injection" },
      message_lacks = { "malicious", "injection" } })
  case("decoded JSON string timeout fails closed",
    '{"action":"allow","category":"timeout"}',
    { block = true, detail = "scan timeout (fail-closed)", category = "timeout", detections = {} })
  case("undecodable string body fails closed", "not json",
    { block = true, detail_has = "fail-closed", category = "unavailable", detections = {} })
  case("empty string body fails closed", "",
    { block = true, detail_has = "fail-closed", category = "unavailable", detections = {} })

  -- cjson.safe failure modes. The FIXTURES stub above only exercises "require
  -- succeeds, decode returns nil, err" (the "undecodable string body" case
  -- just above). These are the two other ways the pcall around require and
  -- decode can fail, and the fail-closed guard must catch both the same way.
  case_with_cjson_loader(
    "cjson.safe require raises a string error fails closed",
    function() error("cjson.safe module not found") end,
    '{"action":"allow","category":"benign"}',
    { block = true, message_has = "Blocked by Prisma AIRS",
      detail = "verdict unavailable (fail-closed)", category = "unavailable", detections = {} })

  -- Mutation check: the error value raised is itself shaped like an allow
  -- verdict. The correct code discards `decoded` whenever `ok` is false
  -- (`resp = ok and decoded or nil`); if that check were ever dropped in
  -- favour of unconditionally using the pcall's second return value, this
  -- case would pass the guardrail open instead of failing it closed.
  case_with_cjson_loader(
    "cjson.safe require raises a table shaped like an allow verdict, still fails closed",
    function() error({ action = "allow", category = "benign" }) end,
    '{"action":"allow","category":"benign"}',
    { block = true, message_has = "Blocked by Prisma AIRS",
      detail = "verdict unavailable (fail-closed)", category = "unavailable", detections = {} })

  case_with_cjson_loader(
    "cjson.safe loads but has no decode function fails closed",
    function() return {} end,
    '{"action":"allow","category":"benign"}',
    { block = true, message_has = "Blocked by Prisma AIRS",
      detail = "verdict unavailable (fail-closed)", category = "unavailable", detections = {} })

  case_with_cjson_loader(
    "cjson.safe decode returns a non-table value fails closed",
    function() return { decode = function() return 42 end } end,
    '{"action":"allow","category":"benign"}',
    { block = true, message_has = "Blocked by Prisma AIRS",
      detail = "verdict unavailable (fail-closed)", category = "unavailable", detections = {} })
end

verdict_cases("scan_verdict", scan_verdict)
verdict_cases("prompt_verdict", prompt_verdict)

-- -----------------------------------------------------------------------------
-- airs_contents. Picks the AIRS content key from $(source) and refuses to
-- build a payload from anything but a string, so a conf table can never be
-- shipped to Prisma AIRS if the implicit by-name injection ever changes.
-- -----------------------------------------------------------------------------
local function check_contents(name, got, key, text)
  local problem = nil
  if type(got) ~= "table" or type(got[1]) ~= "table" then
    problem = "expected { { " .. key .. " = ... } }"
  elseif got[1][key] ~= text then
    problem = string.format("expected %s=%q, got %s", key, text, tostring(got[1][key]))
  elseif #got ~= 1 then
    problem = "expected exactly one content item, got " .. #got
  else
    for k in pairs(got[1]) do
      if k ~= key then problem = "unexpected key in content item: " .. tostring(k) end
    end
  end
  report(name, problem)
end

check_contents("airs_contents: INPUT gives contents[].prompt",
  airs_contents("INPUT", "hello"), "prompt", "hello")
check_contents("airs_contents: OUTPUT gives contents[].response",
  airs_contents("OUTPUT", "world"), "response", "world")
check_contents("airs_contents: empty string is still a string",
  airs_contents("INPUT", ""), "prompt", "")
check_raises("airs_contents: table content raises (implicit conf injection)",
  airs_contents, { params = { api_key = "secret" } }, nil)
check_raises("airs_contents: table as second argument raises (implicit resp, conf)",
  airs_contents, "resp body", { params = { api_key = "secret" } })
check_raises("airs_contents: nil content raises",
  airs_contents, "INPUT", nil)
check_raises("airs_contents: unknown source raises",
  airs_contents, "SIDEWAYS", "hello")

print(string.format("\n1..%d", total))
if failures > 0 then
  print(string.format("# FAILED %d of %d", failures, total))
  os.exit(1)
end
print(string.format("# passed %d of %d", total, total))
