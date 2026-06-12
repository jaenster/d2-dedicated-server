export const meta = {
  name: 'revar-pass2-scan',
  description: 'Scan all 1.14d Game.exe functions; flag those with default-named or untyped-resolved variables',
  phases: [{ title: 'Scan', detail: '30 sonnet agents page list_functions and flag dirty functions' }],
}

const TOTAL = 14457
const BAND = 500
const bands = []
for (let off = 0; off < TOTAL; off += BAND) bands.push(off)

const SCHEMA = {
  type: 'object',
  properties: {
    flagged: { type: 'array', items: { type: 'string' }, description: 'entryPoint addresses of functions needing pass-2 work' },
    scanned: { type: 'number' },
    skippedClean: { type: 'number' },
  },
  required: ['flagged', 'scanned', 'skippedClean'],
  additionalProperties: false,
}

phase('Scan')

const prompt = (off) => `You scan a band of the Diablo 2 1.14d Game.exe in Ghidra (session f4db4b5c) and return which functions still need a second-pass variable cleanup. READ-ONLY — make no edits.

Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__list_functions\`.

Page your band with \`list_functions(sessionId:"f4db4b5c", offset:N, limit:100)\` for N = ${off}, ${off + 100}, ${off + 200}, ${off + 300}, ${off + 400} (stop early if a page returns fewer than 100). For EACH function inspect its \`parameters\` and \`localVariables\` metadata (names + dataType strings — you do NOT need to decompile).

FLAG the function (add its entryPoint to \`flagged\`) if it is NOT in the skip set below AND at least one param or local matches either:
 (a) DEFAULT NAME — name matches any of: \`param_<n>\`, \`param_<n>_<n>\`, \`local_<hex>\`, \`<x>Var<n>\` (uVar/iVar/cVar/bVar/BVar/eVar/fVar/dVar/lVar), \`p<x>Var<n>\` / \`pp<x>Var<n>\` (pDVar/puVar/pcVar/piVar...), \`<x>Stack<...>\` (uStack/iStack/DStack/sStack), \`extraout_*\`, generic \`dwParam/nParam/bParam/dwArg/nArg/pdwParam\`, bare \`_Dst\`, \`uRam*\`, \`register0x*\`; OR
 (b) UNTYPED-RESOLVED — dataType begins with \`undefined1/2/4/8\` AND contains \`/* resolvedType: T */\` where T is a concrete type (a struct pointer like \`D2UnitStrc *\`, an enum like \`eMissilesId\`, or \`BOOL/int/uint/byte/short/...\`). If T is itself \`undefined*\`, do NOT flag on that var.

SKIP (never flag): namespace == \`CRT\`; name starts with \`CRT_\`, \`__\`, or \`_\`; name starts with \`thunk_\`; size < 16; functions whose params+locals are ALL already meaningfully named AND concretely typed (nothing matches (a) or (b)). Storm/Fog/Blizzard subsystems are IN scope.

When in doubt, FLAG (a false flag is cheap; a miss is not).

Return structured output: \`flagged\` = array of entryPoint address strings, \`scanned\` = total functions you looked at, \`skippedClean\` = count skipped because clean/skip-set. No prose.`

const results = await parallel(bands.map((off) => () =>
  agent(prompt(off), { label: `scan@${off}`, phase: 'Scan', model: 'sonnet', schema: SCHEMA })
))

const ok = results.filter(Boolean)
const flagged = ok.flatMap(r => r.flagged || [])
const uniq = Array.from(new Set(flagged))
const scanned = ok.reduce((a, r) => a + (r.scanned || 0), 0)
const skippedClean = ok.reduce((a, r) => a + (r.skippedClean || 0), 0)

log(`scan bands ok=${ok.length}/${bands.length} scanned=${scanned} flagged=${uniq.length} skippedClean=${skippedClean}`)

return { flagged: uniq, scanned, skippedClean, bandsOk: ok.length, bandsTotal: bands.length }
