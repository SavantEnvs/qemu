/* Per-input state for the virtio-9p fuzz target. generic_fuzzer_virtio_9p_args() creates one host directory
 * (g_dir_make_tmp("qemu-fuzz.XXXXXX")) and exports it as a read-write -fsdev local share; nothing empties it,
 * so files a guest creates in one input would be visible to every later input and pile up on disk.
 * This records that directory (glib wrapper, returns the real result unchanged), empties it from a qemu reset
 * handler (the fuzzer calls qemu_system_reset() after every input) and removes it at exit. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Weak: this object is also linked into configure's throwaway test programs, which have no qemu. */
extern void qemu_register_reset(void (*func)(void *opaque), void *opaque) __attribute__((weak));

static char *share_dir;

static int remove_below(const char *path, const struct stat *sb, int flag, struct FTW *ftw)
{
    if (ftw->level > 0) {
        remove(path);
    }
    return 0;
}

static void empty_share(void *opaque)
{
    nftw(share_dir, remove_below, 16, FTW_DEPTH | FTW_PHYS | FTW_MOUNT);
}

static void remove_share(void)
{
    empty_share(NULL);
    rmdir(share_dir);
}

char *g_dir_make_tmp(const char *tmpl, void **error)
{
    static char *(*real)(const char *, void **);
    if (!real) {
        real = (char *(*)(const char *, void **))dlsym(RTLD_NEXT, "g_dir_make_tmp");
    }
    char *dir = real(tmpl, error);
    if (dir && tmpl && !share_dir && !strcmp(tmpl, "qemu-fuzz.XXXXXX")) {
        if (!qemu_register_reset) {
            abort();
        }
        share_dir = strdup(dir);
        qemu_register_reset(empty_share, NULL);
        atexit(remove_share);
    }
    return dir;
}
