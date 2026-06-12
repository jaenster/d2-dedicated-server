export const meta = {
  name: 'revar-pass2-scan2',
  description: 'Fixable-only scan: flag functions with actionable (non-HASH, non-artifact) default-named or untyped-resolved vars',
  phases: [{ title: 'Scan2', detail: '30 sonnet agents flag only fixable residue' }],
}

const TOTAL = 14457
const BAND = 500
const bands = []
for (let off = 0; off < TOTAL; off += BAND) bands.push(off)

const SCHEMA = {
  type: 'object',
  properties: {
    flagged: { type: 'array', items: { type: 'string' } },
    scanned: { type: 'number' },
    skippedClean: { type: 'number' },
  },
  required: ['flagged', 'scanned', 'skippedClean'],
  additionalProperties: false,
}

phase('Scan2')

const prompt = (off) => `You scan a band of Diablo 2 1.14d Game.exe in Ghidra (session f4db4b5c) and return functions that still have FIXABLE variable cleanup left. READ-ONLY — no edits.

Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__list_functions\`.

Page your band: \`list_functions(sessionId:"f4db4b5c", offset:N, limit:100)\` for N = ${off}, ${off + 100}, ${off + 200}, ${off + 300}, ${off + 400} (stop if a page returns <100). For EACH function inspect \`parameters\` and \`localVariables\` (name, dataType, storage) — do NOT decompile.

A var counts as a FIXABLE offender ONLY IF its \`storage\` does NOT start with \`HASH:\` (i.e. it lives in a register like \`EAX:4\`/\`EDI:4\` or on the stack like \`Stack[-0x8]:4\` — those are renameable/retypeable; HASH-stored compiler temporaries are NOT and must be ignored) AND it matches either:
 (a) DEFAULT NAME: \`param_<n>\`, \`param_<n>_<n>\`, \`local_<hex>\`, \`<x>Var<n>\` (uVar/iVar/cVar/bVar/BVar/eVar/fVar/dVar/lVar), \`p<x>Var<n>\`/\`pp<x>Var<n>\` (pcVar/pDVar/puVar/piVar...), \`<x>Stack<n>\` (uStack/iStack/DStack/sStack), generic \`dwParam/nParam/bParam/dwArg/nArg/pdwParam\`, bare \`_Dst\`, \`uRam*\`, \`register0x*\`. EXCLUDE \`in_*\`, \`unaff_*\`, \`extraout_*\` — those are intentional compiler-artifact reads, never flag on them. OR
 (b) UNTYPED-RESOLVED: dataType begins \`undefined1/2/4/8\` AND contains \`/* resolvedType: T */\` where T is concrete (struct pointer / enum / BOOL/int/uint/byte/short/...). Ignore if T is undefined*.

FLAG the function (add entryPoint to \`flagged\`) if it has >=1 fixable offender AND is NOT in the skip set: namespace \`CRT\`; name starts \`CRT_\`/\`__\`/\`_\`; name starts \`thunk_\`; size < 16.

A function whose ONLY remaining default/undefined vars are HASH-stored or in_/unaff_/extraout_ is CLEAN — do not flag it. When unsure whether storage is HASH, read the storage string exactly.

Return: \`flagged\` = entryPoint strings, \`scanned\` = funcs looked at, \`skippedClean\` = count not flagged. No prose.`

const results = await parallel(bands.map((off) => () =>
  agent(prompt(off), { label: `scan2@${off}`, phase: 'Scan2', model: 'sonnet', schema: SCHEMA })
))

const ok = results.filter(Boolean)
const flagged = ok.flatMap(r => r.flagged || [])
const uniq = Array.from(new Set(flagged))
const scanned = ok.reduce((a, r) => a + (r.scanned || 0), 0)
const skippedClean = ok.reduce((a, r) => a + (r.skippedClean || 0), 0)

log(`scan2 bands ok=${ok.length}/${bands.length} scanned=${scanned} fixable-flagged=${uniq.length} clean=${skippedClean}`)

return { flagged: uniq, scanned, skippedClean, bandsOk: ok.length, bandsTotal: bands.length }
