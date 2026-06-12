export const meta = {
  name: 'revar-pass2-scan3',
  description: 'Fact-dump scan: agents list candidate vars, workflow filters deterministically to true fixable worklist',
  phases: [{ title: 'Scan3', detail: '30 sonnet agents dump candidate vars; code filters HASH/artifacts' }],
}

const TOTAL = 14457
const BAND = 500
const bands = []
for (let off = 0; off < TOTAL; off += BAND) bands.push(off)

const SCHEMA = {
  type: 'object',
  properties: {
    funcs: {
      type: 'array',
      description: 'functions with >=1 candidate var',
      items: {
        type: 'object',
        properties: {
          a: { type: 'string', description: 'entryPoint address' },
          c: {
            type: 'array',
            description: 'candidate vars: [name, storage, kind] where kind D=default-name U=undefined-with-concrete-resolvedType',
            items: { type: 'array', items: { type: 'string' } },
          },
        },
        required: ['a', 'c'],
        additionalProperties: false,
      },
    },
    scanned: { type: 'number' },
  },
  required: ['funcs', 'scanned'],
  additionalProperties: false,
}

phase('Scan3')

const prompt = (off) => `Scan a band of Diablo 2 1.14d Game.exe (Ghidra session f4db4b5c). READ-ONLY. For each function you DUMP its candidate variables — do NOT judge whether the function is "done". Be LIBERAL: when unsure, include the var. Code downstream does the strict filtering.

Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__list_functions\`.

Page your band: \`list_functions(sessionId:"f4db4b5c", offset:N, limit:100)\` for N = ${off}, ${off+100}, ${off+200}, ${off+300}, ${off+400} (stop if a page returns <100). Do NOT decompile.

SKIP entirely (omit from output): namespace \`CRT\`; name starts \`CRT_\`/\`__\`/\`_\`; name starts \`thunk_\`; size < 16.

For every OTHER function, examine each entry in \`parameters\` and \`localVariables\`. A var is a CANDIDATE if EITHER:
 - kind \`D\` (default name): its name starts with any of param_ / local_ / iVar / uVar / cVar / bVar / BVar / eVar / fVar / dVar / lVar / pDVar / ppDVar / puVar / pcVar / piVar / uStack / iStack / DStack / sStack / in_ / unaff_ / extraout_ / register0x / uRam, OR equals dwParam/nParam/bParam/dwArg/nArg/pdwParam/_Dst; OR
 - kind \`U\` (undefined-resolved): its dataType begins \`undefined1/2/4/8\` AND contains \`/* resolvedType: T */\` with T a concrete type (NOT another undefined).
(Yes, include in_/unaff_/extraout_ and HASH-stored vars here — downstream code removes them. Your job is just to surface candidates.)

Output: \`funcs\` = array of { a: entryPoint, c: [ [name, storage, kind], ... ] } for every function that has >=1 candidate (skip functions with zero candidates). \`storage\` = the exact storage string from metadata (e.g. "EAX:4", "Stack[-0x8]:4", "HASH:5f..:4"). \`scanned\` = total functions examined. No prose.`

const results = await parallel(bands.map((off) => () =>
  agent(prompt(off), { label: `scan3@${off}`, phase: 'Scan3', model: 'sonnet', schema: SCHEMA })
))

const ok = results.filter(Boolean)
const scanned = ok.reduce((a, r) => a + (r.scanned || 0), 0)

// deterministic strict filter — this is the reliable part
const isHash = (s) => String(s || '').toUpperCase().startsWith('HASH')
const isArtifact = (n) => /^(in_|unaff_|extraout_)/.test(String(n || ''))

const trueFlagged = new Set()
let totalCand = 0, keptCand = 0
let droppedHash = 0, droppedArtifact = 0
for (const r of ok) {
  for (const f of (r.funcs || [])) {
    let keep = false
    for (const cand of (f.c || [])) {
      const [name, storage] = cand
      totalCand++
      if (isHash(storage)) { droppedHash++; continue }
      if (isArtifact(name)) { droppedArtifact++; continue }
      keptCand++
      keep = true
    }
    if (keep) trueFlagged.add(String(f.a).toLowerCase())
  }
}
const addrs = Array.from(trueFlagged)

log(`scan3 ok=${ok.length}/${bands.length} scanned=${scanned} | candidates=${totalCand} kept=${keptCand} droppedHASH=${droppedHash} droppedArtifact=${droppedArtifact} | TRUE-fixable-funcs=${addrs.length}`)

return { flagged: addrs, scanned, totalCand, keptCand, droppedHash, droppedArtifact, bandsOk: ok.length, bandsTotal: bands.length }
