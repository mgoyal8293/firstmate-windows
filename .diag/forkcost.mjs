// Measures the latency the hung-successor test is actually racing:
// spawn("bash",["-lc", ... exec arm script]) -> the arm script's first
// side effect (its `arm=` row) becoming visible to the parent.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "forkcost-"));
const script = join(dir, "arm.sh");
writeFileSync(script, `#!/usr/bin/env bash
printf 'arm=%s\\n' "$$" >> "\${FM_ARM_LOG:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
`, { mode: 0o755 });

const N = Number(process.argv[2] || 40);
const samples = [];
for (let i = 0; i < N; i += 1) {
  const log = join(dir, `log-${i}`);
  const t0 = process.hrtime.bigint();
  const child = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
    cwd: dir,
    env: { ...process.env, FM_HOME: dir, FM_CONFIG_OVERRIDE: join(dir, "config"), FM_WATCH_ARM_SCRIPT: script, FM_ARM_LOG: log },
    stdio: ["ignore", "pipe", "pipe"],
  });
  // poll for the row, exactly the observable the test asserts on
  let ms = null;
  while (ms === null) {
    if (existsSync(log) && statSync(log).size > 0) {
      ms = Number(process.hrtime.bigint() - t0) / 1e6;
      break;
    }
    await new Promise((r) => setTimeout(r, 1));
    if (Number(process.hrtime.bigint() - t0) / 1e6 > 20000) { ms = -1; break; }
  }
  samples.push(ms);
  child.kill("SIGTERM");
  await new Promise((r) => child.on("close", r));
}
samples.sort((a, b) => a - b);
const q = (p) => samples[Math.min(samples.length - 1, Math.floor(p * samples.length))];
console.log(`n=${samples.length} min=${samples[0].toFixed(1)} p50=${q(0.5).toFixed(1)} p90=${q(0.9).toFixed(1)} p99=${q(0.99).toFixed(1)} max=${samples[samples.length-1].toFixed(1)} (ms)`);
