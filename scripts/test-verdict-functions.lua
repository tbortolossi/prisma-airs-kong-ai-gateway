-- =============================================================================
-- Assertions for the ai-custom-guardrail verdict functions.
--
-- This file contains no copy of the Lua under test. scripts/run-lua-tests.sh
-- extracts airs_verdict from config/kongctl/airs-guardrail.yaml and injects it
-- as the globals prompt_verdict and response_verdict, so these assertions can
-- never drift from the shipped configuration.
--
-- Run with: ./scripts/run-lua-tests.sh
-- =============================================================================

local failures = 0
local total = 0

local function check(name, got, want_block, want_message_contains)
  total = total + 1
  local problem = nil

  if type(got) ~= "table" then
    problem = "expected a table, got " .. type(got)
  elseif got.block ~= want_block then
    problem = "expected block=" .. tostring(want_block) .. ", got " .. tostring(got.block)
  elseif want_message_contains
      and not string.find(got.block_message or "", want_message_contains, 1, true) then
    problem = "expected message containing " .. string.format("%q", want_message_contains)
        .. ", got " .. string.format("%q", got.block_message or "<nil>")
  end

  if problem then
    failures = failures + 1
    print(string.format("not ok %d - %s\n  # %s", total, name, problem))
  else
    print(string.format("ok %d - %s", total, name))
  end
end

-- Fail-closed paths. Each of these is a way the scan can fail to produce a
-- usable verdict. Every one of them must block, or the guardrail is bypassable
-- by making Prisma AIRS unavailable.
check("prompt: nil verdict blocks",
  prompt_verdict(nil), true, "fail-closed")
check("prompt: empty table blocks",
  prompt_verdict({}), true, "fail-closed")
check("prompt: missing action blocks",
  prompt_verdict({ category = "benign" }), true, "fail-closed")
check("prompt: non-string action blocks",
  prompt_verdict({ action = 1 }), true, "fail-closed")
check("prompt: category=error blocks despite action=allow",
  prompt_verdict({ action = "allow", category = "error" }), true, "scan error")
check("prompt: category=timeout blocks despite action=allow",
  prompt_verdict({ action = "allow", category = "timeout" }), true, "scan timeout")

-- Allow path. A benign verdict must not block, or the gateway is unusable.
check("prompt: benign allow passes",
  prompt_verdict({ action = "allow", category = "benign" }), false)
check("prompt: allow with no detection fired passes (alert-only profile)",
  prompt_verdict({ action = "allow", category = "benign",
                   prompt_detected = { injection = false } }), false)

-- Block path, against the documented Prisma AIRS scan response shape.
check("prompt: block reports the category",
  prompt_verdict({ action = "block", category = "malicious" }), true, "malicious")
check("prompt: block names the detection that fired",
  prompt_verdict({ action = "block", category = "malicious",
                   prompt_detected = { injection = true, dlp = false } }), true, "injection")
check("prompt: block carries scan_id for SCM correlation",
  prompt_verdict({ action = "block", category = "malicious",
                   scan_id = "abc-123" }), true, "scan_id=abc-123")
check("prompt: detections that did not fire are not listed",
  prompt_verdict({ action = "block", category = "malicious",
                   prompt_detected = { dlp = false } }), true, "malicious")

-- The response direction reads response_detected, not prompt_detected.
check("response: nil verdict blocks",
  response_verdict(nil), true, "fail-closed")
check("response: benign allow passes",
  response_verdict({ action = "allow", category = "benign" }), false)
check("response: block names the response detection",
  response_verdict({ action = "block", category = "malicious",
                     response_detected = { db_security = true } }), true, "db_security")
check("response: prompt_detected is ignored in this direction",
  response_verdict({ action = "block", category = "malicious",
                     prompt_detected = { injection = true } }), true, "malicious")
check("response: undecodable string body blocks",
  response_verdict("not json"), true, "fail-closed")

print(string.format("\n1..%d", total))
if failures > 0 then
  print(string.format("# FAILED %d of %d", failures, total))
  os.exit(1)
end
print(string.format("# passed %d of %d", total, total))
