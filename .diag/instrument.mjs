// Measures, on this machine, the exact quantity the hung-successor case races:
// spawn -> the arm script's first side effect. Reports the full distribution
// against the test's 250ms FM_PI_ARM_READY_TIMEOUT_MS budget.
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
const N = Number(process.argv[2] || 200);
const s = [];
for (let i = 0; i < N; i += 1) {
  const log = join(dir, `log-${i}`);
  const t0 = process.hrtime.bigint();
  const child = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
    cwd: dir,
    env: { ...process.env, FM_HOME: dir, FM_CONFIG_OVERRIDE: join(dir, "config"), FM_WATCH_ARM_SCRIPT: script, FM_ARM_LOG: log },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let ms = -1;
  for (;;) {
    if (existsSync(log) && statSync(log).size > 0) { ms = Number(process.hrtime.bigint() - t0) / 1e6; break; }
    await new Promise((r) => setTimeout(r, 1));
    if (Number(process.hrtime.bigint() - t0) / 1e6 > 20000) break;
  }
  s.push(ms);
  child.kill("SIGTERM");
  await new Promise((r) => child.on("close", r));
}
const over = s.filter((v) => v < 0 || v > 250).length;
s.sort((a, b) => a - b);
const q = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
console.log(`SPAWN_TO_ROW n=${s.length} min=${s[0].toFixed(1)} p50=${q(0.5).toFixed(1)} p90=${q(0.9).toFixed(1)} p99=${q(0.99).toFixed(1)} max=${s[s.length-1].toFixed(1)} over250=${over}`);
