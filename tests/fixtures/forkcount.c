/*
 * tests/fixtures/forkcount.c - count process creations per side of the
 * session-start runtime bound.
 *
 * WHY THIS IS A COMMITTED FIXTURE. The nesting margin in
 * bin/fm-session-start-bound-lib.sh is derived from how many subprocesses the
 * PARENT creates outside the bounded child, and that count had no automated
 * guard: it was re-counted by hand each round and pasted into a literal, so the
 * suite could only catch the margin shrinking and never the count rising into
 * it. Building this at test time and recounting turns the margin's own input
 * into something the suite can fail on.
 *
 * WHAT IS COUNTED. One record per fork(), execve() and posix_spawn(). Process
 * creations are the FORK records plus the SPAWN records; EXEC records are
 * exec-after-fork and are not separate creations, so counting them too would
 * double every ordinary command. bash uses fork+execve rather than posix_spawn,
 * so SPAWN is expected to be zero and the caller asserts that rather than
 * assuming it.
 *
 * HOW THE TWO SIDES ARE TOLD APART, and why not by process tree. The bounded
 * child is launched through `env FM_SESSION_START_STAGE_FILE=...`, so that
 * variable is present in the child's environment and absent in the parent's.
 * Each record therefore carries its own side and no tree walk is needed - which
 * matters, because the digest detaches its network stage into its own process
 * group, the subtree reparents, and a ppid walk fragments and silently
 * undercounts.
 *
 * RECORD FORMAT, one line per call, append-only:
 *   <FORK|EXEC|SPAWN> <TAB> <parent|child>
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

static void forkcount_record(const char *kind) {
  const char *path = getenv("FORKCOUNT_LOG");
  const char *side;
  FILE *out;

  if (path == NULL) return;
  side = getenv("FM_SESSION_START_STAGE_FILE") == NULL ? "parent" : "child";
  out = fopen(path, "a");
  if (out == NULL) return;
  fprintf(out, "%s\t%s\n", kind, side);
  fclose(out);
}

pid_t fork(void) {
  static pid_t (*real_fork)(void);
  if (real_fork == NULL) real_fork = dlsym(RTLD_NEXT, "fork");
  forkcount_record("FORK");
  return real_fork();
}

int execve(const char *path, char *const argv[], char *const envp[]) {
  static int (*real_execve)(const char *, char *const[], char *const[]);
  if (real_execve == NULL) real_execve = dlsym(RTLD_NEXT, "execve");
  forkcount_record("EXEC");
  return real_execve(path, argv, envp);
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *attrp,
                char *const argv[], char *const envp[]) {
  static int (*real_spawn)(pid_t *, const char *,
                           const posix_spawn_file_actions_t *,
                           const posix_spawnattr_t *,
                           char *const[], char *const[]);
  if (real_spawn == NULL) real_spawn = dlsym(RTLD_NEXT, "posix_spawn");
  forkcount_record("SPAWN");
  return real_spawn(pid, path, file_actions, attrp, argv, envp);
}
