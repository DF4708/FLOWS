/* FLOW.app main executable — compiled Mach-O so TCC attributes the child
 * runner's file access to FLOW.app (which holds Full Disk Access), not to
 * /bin/bash. Stays alive as the responsible parent via posix_spawn + wait. */
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
extern char **environ;
int main(void) {
    const char *proj = "/Users/soulary/Documents/Coding_Files/FLOWS";
    const char *script = "/Users/soulary/Documents/Coding_Files/FLOWS/scripts/autonomous_test_runner.sh";
    /* Fail loudly if we cannot enter the project dir: the R app dyn.load()s its
     * native core from getwd()/rust/target, so running from an unexpected cwd
     * could load a planted dylib. Never spawn the runner from the wrong place. */
    if (chdir(proj) != 0) return 2;
    char *argv[] = { "/bin/bash", (char *)script, (char *)0 };
    pid_t pid;
    if (posix_spawn(&pid, "/bin/bash", NULL, NULL, argv, environ) != 0) return 1;
    int st; waitpid(pid, &st, 0);            /* FLOW stays the responsible parent */
    return WIFEXITED(st) ? WEXITSTATUS(st) : 3;
}
