/**
 * kcc-dsh-policy-gate — KCC policy gate bundle for DeepSeek Harness
 * (Plan 08, Task 5: Hardened DSH profile + Cordis mutation guard).
 *
 * The bundle mounts ONE composition row (`id: kcc-policy-gate`) that:
 *
 *  1. registers a *monotonic* Cordis execution guard through the real
 *     `tools/pre-execute` waterfall via `ctx.tools.guard(...)` — every
 *     tool call that is not on the exact post-lock allowlist is denied
 *     with a text reason (no allow result exists, so no other guard or
 *     listener can turn a denial back into permission).  No fake session
 *     tag: enforcement is the runtime's own guard layer;
 *  2. registers exactly three KCC tools:
 *       - `kcc_harness_status` — read-only sandbox/approval/guard probe;
 *       - `kcc_policy_write` — governed write wrapper;
 *       - `kcc_policy_exec`  — governed process wrapper.
 *
 * The exact fail-closed allowlist (dsh_gate.py mirrors it): native
 * `read`, `read_image`, `glob`, `grep`, `todo_write` plus the exact KCC
 * wrappers above.  Raw `bash` / `pwsh` / `terminal` / `write` / `edit` /
 * `str_replace` / `job_kill` / `web_search` / `web_fetch` /
 * `create_goal` / `update_goal` / `subagent*` / `workflow` / `ralph` /
 * `run_code` / `cordis_*` / `mcp__*` and every unknown tool DENY.  There
 * is no controller or resume wrapper: KCC owns controller, status and
 * resume.
 *
 * The wrappers never decide anything: they derive the workspace from the
 * calling session (`exec.agent.session`), bind the request to the KCC
 * run/task/lease identity the worker was dispatched with, and hand the
 * untrusted operation request to the LOCAL Python policy gate over
 * stdin (`kcc-autobuild gate-write` / `gate-exec`).  The gate reloads
 * the durable run, rejects stale leases, verifies the signed policy
 * bundle and only then mints/audits a decision token and executes.
 * No raw secret ever reaches the command line: the gate reads its HMAC
 * secret from the owner-only file referenced by `gateSecretFile`.
 *
 * The request payload always rides stdin; the command line carries only
 * fixed configuration (`gateCommand`, `--bundle`, `--secret-file`,
 * `--timeout`), never model input.
 */
import Schema from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'kcc-policy-gate'

export const Config = Schema.object({
  /** The local kcc-autobuild CLI (absolute path or PATH command). */
  gateCommand: Schema.string().default('kcc-autobuild'),
  /** Signed policy bundle path; empty = gate default (fails closed). */
  gateBundleFile: Schema.string().default(''),
  /** Owner-only HMAC secret file; empty = env KCC_AUTOBUILD_POLICY_SECRET_FILE. */
  gateSecretFile: Schema.string().default(''),
  /** Per-request gate budget (including a 15s shell-seam margin). */
  gateTimeoutMs: Schema.number().min(1000).max(3600000).default(600000),
})

export const inject = ['tools', 'shell']

/** Exact post-lock allowlist (mirrors `kcc_autobuild.dsh_gate`). */
const ALLOWED_TOOLS = new Set([
  'read',
  'read_image',
  'glob',
  'grep',
  'todo_write',
  'kcc_policy_exec',
  'kcc_policy_write',
  'kcc_harness_status',
])

/** Denied name families: `subagent*`, `cordis_*`, `mcp__*`, plus the
 * slash-named Cordis/Workflow observer tools. */
const DENIED_PREFIXES = ['subagent', 'cordis_', 'mcp__', 'cordis/', 'workflow/']

/** Raw mutation/orchestration tool names named by the plan contract. */
const DENIED_NAMES = new Set([
  'bash',
  'pwsh',
  'terminal',
  'write',
  'edit',
  'str_replace',
  'str_replace_editor',
  'job_kill',
  'web_search',
  'web_fetch',
  'create_goal',
  'update_goal',
  'goal',
  'workflow',
  'ralph',
  'run_code',
])

function allowed(name) {
  return ALLOWED_TOOLS.has(name)
}

function denial(name) {
  const family = DENIED_PREFIXES.find((prefix) => String(name).startsWith(prefix))
  if (family) {
    return (
      `KCC policy gate: tool "${name}" is a denied ` +
      `"${family.replace(/[\/_]+$/, '')}*" family operation — fail closed (denied without prompt). ` +
      `Go through kcc_policy_exec / kcc_policy_write if the operation is governed.`
    )
  }
  if (DENIED_NAMES.has(name)) {
    return (
      `KCC policy gate: tool "${name}" is not on the exact post-lock allowlist ` +
      `(read, read_image, glob, grep, todo_write, kcc_policy_exec, ` +
      `kcc_policy_write, kcc_harness_status) — denied without prompt.`
    )
  }
  return (
    `KCC policy gate: unknown tool "${name}" — fail closed (denied without prompt). ` +
    `Go through kcc_policy_exec / kcc_policy_write if the operation is governed.`
  )
}

function sessionOf(exec) {
  if (!exec || !exec.agent) return null
  return exec.agent.session || null
}

function cwdOf(session) {
  if (!session || !session.header || typeof session.header.cwd !== 'string') return ''
  return session.header.cwd
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`
}

/**
 * Call the local Python policy gate: fixed argv + the untrusted request
 * JSON on stdin, launched in the session's workspace (the gate's process
 * cwd is the confinement anchor, and the request never carries a cwd).
 */
async function callGate(ctx, cfg, tool, request, session) {
  const shell = ctx.get('shell')
  if (!shell || typeof shell.resolve !== 'function' || typeof shell.run !== 'function') {
    return {
      ok: false,
      error: 'KCC policy gate: no shell seam available to reach the local Python policy gate',
    }
  }
  const subcommand = tool === 'kcc_policy_write' ? 'gate-write' : 'gate-exec'
  const argv = [shellQuote(cfg.gateCommand), subcommand]
  if (cfg.gateBundleFile) argv.push('--bundle', shellQuote(cfg.gateBundleFile))
  if (cfg.gateSecretFile) argv.push('--secret-file', shellQuote(cfg.gateSecretFile))
  argv.push('--timeout', String(Math.max(1, Math.floor(cfg.gateTimeoutMs / 1000))))
  const workdir = cwdOf(session)
  const spec = {
    command: argv.join(' '),
    timeoutMs: cfg.gateTimeoutMs + 15000,
    stdoutMaxBytes: 1 << 20,
    stdin: JSON.stringify(request),
  }
  // The wrapper derives the workspace from the session: the gate process
  // starts there and confines every write under it.
  if (workdir) spec.workdir = workdir
  let res
  try {
    res = await shell.run(shell.resolve(spec))
  } catch (error) {
    return { ok: false, error: `KCC policy gate failed to launch: ${error.message}` }
  }
  if (!res || res.exitCode === null || res.exitCode === undefined) {
    const detail = res && res.stderr && res.stderr.text ? res.stderr.text.slice(0, 400) : ''
    return { ok: false, error: `KCC policy gate aborted: ${detail || 'unknown signal'}` }
  }
  const text = (res.stdout && res.stdout.text) || ''
  if (!text && res.exitCode !== 0) {
    const detail = (res.stderr && res.stderr.text || '').slice(0, 400)
    return { ok: false, error: `KCC policy gate exited ${res.exitCode}: ${detail}` }
  }
  try {
    const decision = JSON.parse(text)
    if (decision && decision.allowed === true) {
      return { ok: true, decision }
    }
    return {
      ok: false,
      error: (decision && decision.reason) || 'KCC policy gate denied the request',
    }
  } catch (error) {
    return { ok: false, error: `KCC policy gate returned an unreadable response: ${error.message}` }
  }
}

export async function apply(ctx, config) {
  const cfg = { ...config }

  // 1. Monotonic guard through the real runtime guard layer.  A guard can
  //    only deny (no allow result), so the exact allowlist is fail-closed.
  //    Visibility restriction is NOT applied here: the runtime deliberately
  //    refuses a context-global `tools.restrict` (it would mask every
  //    agent), and the guard is the enforcement — a denied call fails
  //    closed without a prompt regardless of what the model sees.
  ctx.tools.guard((execution) => {
    const tool = execution && execution.name
    if (tool && allowed(tool)) return undefined
    return denial(tool)
  })

  // 3. The exact KCC tools.
  ctx.tools.register(defineTool({
    name: 'kcc_harness_status',
    description:
      'Read-only KCC harness status probe: reports the effective sandbox mode, ' +
      'approval policy, and mutation guard of the CURRENT profile and session. ' +
      'Never mutates anything.',
    parameters: {},
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          sandbox: { type: 'string' },
          approval: { type: 'string' },
          guard: { type: 'string' },
        },
      },
      render(args, value) {
        return [{ type: 'text', text: JSON.stringify(value) }]
      },
    },
    async execute(args, exec) {
      const session = sessionOf(exec)
      const sandboxPolicy = ctx.get('sandboxPolicy')
      const approval = ctx.get('approval')
      let sandbox = 'unknown'
      if (sandboxPolicy && session) {
        try {
          const policy = sandboxPolicy.resolve({ session })
          sandbox = (policy && policy.mode) || 'unknown'
        } catch {
          sandbox = 'unknown'
        }
      }
      let approvalPolicy = 'unknown'
      if (approval && session) {
        try {
          approvalPolicy = approval.effectivePolicy(session)
        } catch {
          approvalPolicy = 'unknown'
        }
      }
      return {
        sandbox,
        approval: approvalPolicy,
        guard: 'kcc-policy-gate',
      }
    },
  }))

  const requestBase = (args, tool) => {
    const a = args && typeof args === 'object' ? args : {}
    return {
      version: 1,
      run_id: a.run_id,
      task_id: a.task_id,
      lease_id: a.lease_id,
      generation: a.generation,
      tool,
    }
  }

  ctx.tools.register(defineTool({
    name: 'kcc_policy_write',
    description:
      'Governed write: the ONLY way a post-lock worker may mutate the ' +
      'workspace filesystem. Sends the untrusted operation request to the ' +
      'KCC policy gate (durable run + lease + signed policy + decision ' +
      'token audit) and performs the canonical-path-confined write only when ' +
      'the gate allows. Raw write/edit tools fail closed.',
    parameters: {
      run_id: { type: 'string', required: true, description: 'The KCC autobuild run id (from the task handoff pack).' },
      task_id: { type: 'string', required: true, description: 'The KCC task id (from the task handoff pack).' },
      lease_id: { type: 'string', required: true, description: 'The KCC lease id (from the task handoff pack).' },
      generation: { type: 'integer', required: true, description: 'The lease generation, strictly positive.' },
      path: { type: 'string', required: true, description: 'Workspace-relative target path (no absolute path, no .., no glob).' },
      content: { type: 'string', required: true, description: 'Full UTF-8 text content to write.' },
      data_class: { type: 'string', description: 'KCC data classification (default PUBLIC).' },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render(args, value) {
        return [{ type: 'text', text: JSON.stringify(value, null, 2) }]
      },
    },
    async execute(args, exec) {
      const session = sessionOf(exec)
      if (!session || !cwdOf(session)) {
        return {
          ok: false,
          error: 'KCC policy gate: the wrapper derives the workspace from the session, but no session cwd is available',
        }
      }
      const a = args && typeof args === 'object' ? args : {}
      const request = {
        ...requestBase(a, 'kcc_policy_write'),
        operation: {
          kind: 'write',
          path: a.path,
          content: a.content,
          data_class: a.data_class || 'PUBLIC',
        },
      }
      return callGate(ctx, cfg, 'kcc_policy_write', request, session)
    },
  }))

  ctx.tools.register(defineTool({
    name: 'kcc_policy_exec',
    description:
      'Governed process execution: the ONLY way a post-lock worker may run ' +
      'a subprocess. Sends the untrusted operation request to the KCC policy ' +
      'gate (durable run + lease + signed policy + decision token audit) and ' +
      'executes the exact argv list (no shell, no raw secrets in the ' +
      'environment) only when the gate allows. Raw bash/pwsh/terminal fail closed.',
    parameters: {
      run_id: { type: 'string', required: true, description: 'The KCC autobuild run id (from the task handoff pack).' },
      task_id: { type: 'string', required: true, description: 'The KCC task id (from the task handoff pack).' },
      lease_id: { type: 'string', required: true, description: 'The KCC lease id (from the task handoff pack).' },
      generation: { type: 'integer', required: true, description: 'The lease generation, strictly positive.' },
      command: { type: 'string', required: true, description: 'A plain program name (never a path); the signed policy names it exactly.' },
      args: { type: 'array', items: { type: 'string' }, description: 'Exact argv entries after the program (no shell metacharacters).' },
      data_class: { type: 'string', description: 'KCC data classification (default PUBLIC).' },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render(args, value) {
        return [{ type: 'text', text: JSON.stringify(value, null, 2) }]
      },
    },
    async execute(args, exec) {
      const session = sessionOf(exec)
      if (!session || !cwdOf(session)) {
        return {
          ok: false,
          error: 'KCC policy gate: the wrapper derives the workspace from the session, but no session cwd is available',
        }
      }
      const a = args && typeof args === 'object' ? args : {}
      const request = {
        ...requestBase(a, 'kcc_policy_exec'),
        operation: {
          kind: 'exec',
          command: a.command,
          args: Array.isArray(a.args) ? a.args : [],
          data_class: a.data_class || 'PUBLIC',
        },
      }
      return callGate(ctx, cfg, 'kcc_policy_exec', request, session)
    },
  }))
}
