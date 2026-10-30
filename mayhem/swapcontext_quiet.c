/* Forwards swapcontext() to libc. ASan's interceptor prints "ASan doesn't fully support makecontext/
 * swapcontext..." to stderr at qemu's first coroutine switch, and Mayhem reports that line as a crash for
 * every input. qemu already tells ASan about its coroutine stacks (__sanitizer_start/finish_switch_fiber). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <ucontext.h>

int swapcontext(ucontext_t *oucp, const ucontext_t *ucp)
{
    static int (*real)(ucontext_t *, const ucontext_t *);
    if (!real) {
        real = (int (*)(ucontext_t *, const ucontext_t *))dlsym(RTLD_NEXT, "swapcontext");
    }
    return real(oucp, ucp);
}
