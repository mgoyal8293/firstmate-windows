// Load-sensitivity curve for the quantity the compressed test budget must
// outrun: spawn a login bash, source the profile, exec the arm script, append
// one line. Reported against the test's current 250ms budget.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const dir = mkdtempSync(join(tmpdir(), "loadcurve-"));
const script = join(dir, "arm.sh");
writeFileSync(script, `#!/usr/bin/env bash
printf 'arm=%s\\n' "$$" >> "\${FM_ARM_LOG:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
`, { mode: 0o755 });

async function sample(n, tag) {
  const s = [];
  for (let i = 0; i < n; i += 1) {
    const log = join(dir, `${tag}-${i}`);
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
      if (Number(process.hrtime.bigint() - t0) / 1e6 > 30000) break;
    }
    s.push(ms < 0 ? 30000 : ms);
    child.kill("SIGTERM");
    await new Promise((r) => child.on("close", r));
  }
  const over = s.filter((v) => v > 250).length;
  s.sort((a, b) => a - b);
  const q = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
  console.log(`LOADCURVE ${tag} n=${s.length} p50=${q(0.5).toFixed(0)} p90=${q(0.9).toFixed(0)} p99=${q(0.99).toFixed(0)} max=${s[s.length-1].toFixed(0)} over250=${over}`);
}

const spinners = [];
function addLoad(k) {
  for (let i = 0; i < k; i += 1) spinners.push(spawn("bash", ["-c", "while :; do :; done"], { stdio: "ignore" }));
}
for (const k of [0, 2, 4, 8, 16]) {
  addLoad(k - spinners.length > 0 ? k - spinners.length : 0);
  await new Promise((r) => setTimeout(r, 800));
  await sample(120, `spinners=${k}`);
}
for (const c of spinners) c.kill("SIGKILL");
