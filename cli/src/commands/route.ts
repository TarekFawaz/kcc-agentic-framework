import { parse, workspace } from "../args";
import { routeAll } from "../run/routing";

/**
 * `kcc route [SPEC-ID] [--dry-run] [--json]`
 *   Decides the model and reasoning effort for every backlog item of a spec from what the architect and the planner
 *   said about it (Complexity, files, domain, CR-7 risk) and writes the result into the plan as `## Routing`.
 *   `kcc run` does this itself after SPECS; in a chat run the orchestrator runs it after the plan. Nothing is spawned.
 */
export function route(argv: string[]): number {
  const { values, positionals } = parse(argv, ["dry-run", "json"], ["dir"]);
  const root = workspace(values.dir);
  const only = positionals.find((p) => /^SPEC-\d+/i.test(p));
  const routed = routeAll(root, only, values["dry-run"] === true);
  if (values.json) {
    console.log(JSON.stringify(routed.map((r) => ({ spec: r.spec, routes: r.routes })), null, 2));
    return routed.length ? 0 : 1;
  }
  if (!routed.length) {
    console.log("No plan with a Backlog Coverage table (Item | Type | Dialect | Complexity | Wave) found" + (only ? ` for ${only}` : "") + ".");
    return 1;
  }
  for (const r of routed) {
    console.log(`${r.spec}${values["dry-run"] ? " (dry run)" : " (written to plan.md)"}`);
    for (const x of r.routes) console.log(`  ${x.key.padEnd(14)} wave ${x.wave.padEnd(2)} ${x.tier.padEnd(9)} ${x.model.padEnd(18)} ${x.effort.padEnd(6)} ${x.why}`);
  }
  return 0;
}
