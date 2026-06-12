export const meta = {
  name: 'revar-pass2-sweep2',
  description: 'Improved retype-first sweep: smaller batches, no schema, apply ALL retypes incl scalars',
  phases: [{ title: 'Sweep2', detail: 'sonnet agents, 12 funcs each, retype-first' },
           { title: 'Commit', detail: 'save_session + commit per wave' }],
}

// args = { addresses: [...] }  — true fixable worklist from scan3 (bake via sweep2.run.js)
const addresses = (args && args.addresses) ? args.addresses : []
const BATCH = 12          // smaller than v1's 25 — v1 agents truncated/rushed long batches
const WAVE_BATCHES = 8

function chunk(arr, n) { const o = []; for (let i = 0; i < arr.length; i += n) o.push(arr.slice(i, i + n)); return o }
const batches = chunk(addresses, BATCH)
const waves = chunk(batches, WAVE_BATCHES)

const processPrompt = (addrs) => `Second-pass type-aware variable cleanup on Diablo 2 1.14d Game.exe in Ghidra (session f4db4b5c). Pass sessionId:"f4db4b5c" on every call. A prior sweep UNDER-DID the retype job — your priority is to apply EVERY resolved type, including scalars.

Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__decompile,mcp__claude_ai_ghidra_mcp__set_function_variable_name,mcp__claude_ai_ghidra_mcp__set_function_variable_type\`.

YOUR FUNCTIONS (${addrs.length}): ${JSON.stringify(addrs)}

Process EVERY function — do not stop early, do not skip any. For EACH: \`decompile(address)\`, then:

JOB 1 FIRST, EXHAUSTIVELY — apply resolved types. For EVERY local/param whose declared dataType is \`undefined1/2/4/8\` and whose entry shows \`/* resolvedType: T */\` with T concrete, call \`set_function_variable_type(functionAddress, variableName, dataType:T)\`. This INCLUDES scalars: \`int\`, \`uint\`, \`int32_t\`, \`uint32_t\`, \`BOOL\`, \`byte\`, \`short\`, \`char\`, enums, AND struct pointers. Do NOT skip scalar retypes — they are the bulk of what the last pass missed. Skip a var only if T is itself \`undefined*\`, or the call errors with "Storage can't be resized" (HASH-stored — leave it).

JOB 2 — rename residual generics: \`iVarN uVarN cVarN bVarN BVarN eVarN fVarN dVarN lVarN pDVarN ppDVarN puVarN pcVarN piVarN\`, \`local_XX\`, \`uStackN iStackN DStackN sStackN\`, \`param_N\`, \`param_N_NN\`, \`dwParam nParam bParam dwArg nArg pdwParam\` -> meaningful D2-Hungarian names from struct-field accesses + called-function names (p ptr, pp ptr-to-ptr, n int/id, b BOOL, e enum, dw dword, w word, by byte, sz cstring, i/j loop). Leave \`in_*/unaff_*/extraout_*\` and HASH-stored temporaries alone unless trivially clear.

Do NOT save_session or commit.

Return a terse tally: "<N> funcs, <R> retypes, <M> renames, <E> errors" plus one line on anything odd. Keep under 600 chars. The tally is secondary — doing ALL the edits is primary.`

const commitPrompt = (label) => `Persist Ghidra. Load tools: ToolSearch query \`select:mcp__claude_ai_ghidra_mcp__save_session,mcp__claude_ai_ghidra_mcp__commit\`. Call save_session(sessionId:"f4db4b5c") then commit(sessionId:"f4db4b5c", message:"revar pass2 sweep2: ${label}"). Reply with the version number or error.`

log(`sweep2 start: ${addresses.length} funcs, ${batches.length} batches (x${BATCH}), ${waves.length} waves`)

for (let w = 0; w < waves.length; w++) {
  const wave = waves[w]
  const tag = `wave ${w + 1}/${waves.length}`
  await parallel(wave.map((b, i) => () =>
    agent(processPrompt(b), { label: `${tag} b${i + 1}`, phase: 'Sweep2', model: 'sonnet' })
  ))
  const ver = await agent(commitPrompt(tag), { label: `commit ${tag}`, phase: 'Commit', model: 'sonnet' })
  log(`${tag} committed -> ${String(ver).slice(0, 60)}`)
}

return { addresses: addresses.length, batches: batches.length, waves: waves.length }
