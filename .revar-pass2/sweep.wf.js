export const meta = {
  name: 'revar-pass2-sweep',
  description: 'Retype-then-rename sweep over the pass-2 worklist; save+commit after each wave',
  phases: [{ title: 'Sweep', detail: 'sonnet agents retype undefined->resolvedType then rename generics' },
           { title: 'Commit', detail: 'save_session + commit per wave' }],
}

// args = { addresses: ["0x...", ...] }  worklist from the scan phase
const addresses = (args && args.addresses) ? args.addresses : []
const BATCH = 25          // funcs per agent
const WAVE_BATCHES = 8    // agents run in parallel per wave (matches pass-1 proven width)

function chunk(arr, n) {
  const out = []
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n))
  return out
}

const batches = chunk(addresses, BATCH)
const waves = chunk(batches, WAVE_BATCHES)

const STAT = {
  type: 'object',
  properties: {
    funcs: { type: 'number' },
    retyped: { type: 'number' },
    renamed: { type: 'number' },
    errors: { type: 'number' },
    notes: { type: 'string' },
  },
  required: ['funcs', 'retyped', 'renamed', 'errors'],
  additionalProperties: false,
}

const processPrompt = (addrs) => `Second-pass type-aware variable cleanup on Diablo 2 1.14d Game.exe in Ghidra (session f4db4b5c). Pass \`sessionId:"f4db4b5c"\` on every call.

Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__decompile,mcp__claude_ai_ghidra_mcp__set_function_variable_name,mcp__claude_ai_ghidra_mcp__set_function_variable_type,mcp__claude_ai_ghidra_mcp__get_function_info\`.

YOUR FUNCTIONS (entryPoint addresses): ${JSON.stringify(addrs)}

For EACH address: \`decompile(address)\`. Then two jobs:

JOB 1 — APPLY RESOLVED TYPES (primary): any local/param whose declared dataType is \`undefined1/2/4/8\` but whose entry shows \`/* resolvedType: T */\` with T a CONCRETE type (struct pointer e.g. \`D2UnitStrc *\`,\`D2MonStatsTxt *\`,\`D2RoomStrc *\`; enum e.g. \`eMissilesId\`,\`eD2UnitType\`,\`eD2States\`; or \`BOOL/int/uint/int32_t/byte/short/...\`) -> \`set_function_variable_type(functionAddress, variableName, dataType:T)\`. Apply for EVERY such var. Skip only if T is itself \`undefined*\`. If a retype errors (e.g. "Storage can't be resized" on HASH-stored vars) skip it and count it as an error — do not fight it.

JOB 2 — RENAME RESIDUAL GENERICS: rename any var still on a decompiler default to a meaningful D2-Hungarian name from struct-field accesses + called-function names. Defaults: \`iVarN uVarN cVarN bVarN BVarN eVarN fVarN dVarN lVarN pDVarN ppDVarN puVarN pcVarN piVarN\`, \`local_XX\`, \`uStackN iStackN DStackN sStackN\`, \`extraout_*\`, \`in_*/unaff_*\` (only if meaning is clear), params \`param_N\`,\`param_N_NN\`, generic \`dwParam nParam bParam dwArg nArg pdwParam\`. Use \`set_function_variable_name(functionAddress, oldName, newName)\`.

Convention: p ptr, pp ptr-to-ptr, n int/count/id, b bool/BOOL, e enum, dw dword, w word, by byte, sz cstring, i/j loop counters. Leave already-meaningful names unless the new type proves them wrong.

SKIP a function entirely if its name starts with \`CRT_\`/\`__\`/\`_\`, namespace is \`CRT\`, it is a \`thunk_*\`, or it has no locals/params to fix.

Do NOT save_session or commit.

Return structured stats: funcs (count processed), retyped (total type changes applied), renamed (total renames applied), errors (failed calls), notes (<=200 chars, any surprises).`

const commitPrompt = (label) => `Persist the Ghidra session. Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__save_session,mcp__claude_ai_ghidra_mcp__commit\`. Call \`save_session(sessionId:"f4db4b5c")\` then \`commit(sessionId:"f4db4b5c", message:"revar pass2 sweep: ${label}")\`. Reply only with the committed version number or any error.`

log(`sweep start: ${addresses.length} funcs, ${batches.length} batches, ${waves.length} waves (width ${WAVE_BATCHES})`)

const totals = { funcs: 0, retyped: 0, renamed: 0, errors: 0 }

for (let w = 0; w < waves.length; w++) {
  const wave = waves[w]
  const tag = `wave ${w + 1}/${waves.length}`
  const res = await parallel(wave.map((b, i) => () =>
    agent(processPrompt(b), { label: `${tag} b${i + 1}`, phase: 'Sweep', model: 'sonnet', schema: STAT })
  ))
  const ok = res.filter(Boolean)
  for (const r of ok) {
    totals.funcs += r.funcs || 0
    totals.retyped += r.retyped || 0
    totals.renamed += r.renamed || 0
    totals.errors += r.errors || 0
  }
  // barrier already passed (parallel awaited) -> safe to persist
  const ver = await agent(commitPrompt(tag), { label: `commit ${tag}`, phase: 'Commit', model: 'sonnet' })
  log(`${tag} done: +${ok.reduce((a, r) => a + (r.retyped || 0), 0)} retyped, +${ok.reduce((a, r) => a + (r.renamed || 0), 0)} renamed | commit -> ${String(ver).slice(0, 80)} | cumulative funcs=${totals.funcs}`)
}

return { ...totals, waves: waves.length, batches: batches.length, addresses: addresses.length }
