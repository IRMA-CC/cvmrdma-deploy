#define _GNU_SOURCE
#include <assert.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#define errExit(msg)        \
    do {                    \
        perror(msg);        \
        exit(EXIT_FAILURE); \
    } while (0)

#define PAGE_SIZE 4096

static void* fault_handler_thread(void* arg) {
    long uffd;                  /* userfaultfd file descriptor */
    uffd = (long) arg;
    static struct uffd_msg  msg;  /* Data read from userfaultfd */

    /* Loop, handling incoming events on the userfaultfd
       file descriptor. */

    for (;;) {
        /* See what poll() tells us about the userfaultfd. */

        struct pollfd pollfd;
        int nready;
        pollfd.fd = uffd;
        pollfd.events = POLLIN;
        nready = poll(&pollfd, 1, -1);
        if (nready == -1)
            errExit("poll");

        printf("\nfault_handler_thread():\n");
        printf(
            "    poll() returns: nready = %d; "
            "POLLIN = %d; POLLERR = %d\n",
            nready, (pollfd.revents & POLLIN) != 0,
            (pollfd.revents & POLLERR) != 0);

        int nread = read(uffd, &msg, sizeof(msg));
        if (nread == 0) {
            printf("EOF on userfaultfd!\n");
            exit(EXIT_FAILURE);
        }

        if (nread == -1)
            err(EXIT_FAILURE, "read");

        /* We expect only one kind of event; verify that assumption. */

        if (msg.event != UFFD_EVENT_PAGEFAULT) {
            fprintf(stderr, "Unexpected event on userfaultfd\n");
            exit(EXIT_FAILURE);
        }

        printf("    UFFD_EVENT_PAGEFAULT event: ");
        printf("flags = %"PRIx64"; ", msg.arg.pagefault.flags);
        printf("address = %"PRIx64"\n", msg.arg.pagefault.address);

        assert(msg.arg.pagefault.flags & UFFD_PAGEFAULT_FLAG_WP);
        assert(msg.arg.pagefault.flags & UFFD_PAGEFAULT_FLAG_WRITE);

        // make page writable via UFFDIO_WRITEPROTECT ioctl
        struct uffdio_writeprotect uffdio_wp = {
            .range = {
                .start = msg.arg.pagefault.address,// & ~(PAGE_SIZE - 1),
                .len = PAGE_SIZE,
            },
            .mode = 0,
        };
        if (ioctl(uffd, UFFDIO_WRITEPROTECT, &uffdio_wp) == -1)
            errExit("ioctl-UFFDIO_WRITEPROTECT");

    }
}

int main() {
    uint64_t len = 3 * PAGE_SIZE;

    /* Create and enable userfaultfd object. */

    long uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);
    if (uffd == -1)
        errExit("userfaultfd");

    struct uffdio_api uffdio_api = {
        .api = UFFD_API,
        .features = UFFD_FEATURE_PAGEFAULT_FLAG_WP,
    };
    if (ioctl(uffd, UFFDIO_API, &uffdio_api) == -1)
        errExit("ioctl-UFFDIO_API");

    char * addr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
    if (addr == MAP_FAILED)
        errExit("mmap");

    printf("Address returned by mmap() = %p\n", addr);

    /* Register the memory range of the mapping we just created for
       handling by the userfaultfd object. */
    struct uffdio_register uffdio_register = {
        .range = {
            .start = (unsigned long) addr,
            .len = len,
        },
        .mode = UFFDIO_REGISTER_MODE_WP | UFFDIO_REGISTER_MODE_MISSING,
        //.mode = UFFDIO_REGISTER_MODE_WP,
    };
    if (ioctl(uffd, UFFDIO_REGISTER, &uffdio_register) == -1)
        errExit("ioctl-UFFDIO_REGISTER");

    struct uffdio_writeprotect uffdio_wp = {
        .range = {
            .start = (unsigned long) addr,
            .len = len,
        },
        .mode = UFFDIO_WRITEPROTECT_MODE_WP,
    };
    if (ioctl(uffd, UFFDIO_WRITEPROTECT, &uffdio_wp) == -1)
        errExit("ioctl-UFFDIO_WRITEPROTECT");

    /* Create a thread that will process the userfaultfd events. */
    pthread_t thr;
    int s = pthread_create(&thr, NULL, fault_handler_thread, (void*) uffd);
    if (s != 0) {
        errno = s;
        errExit("pthread_create");
    }

    /* Main thread now touches memory in the mapping, touching
       locations 1024 bytes apart. This will trigger userfaultfd
       events for all pages in the region. */

    size_t l;
    l = 0xf; /* Ensure that faulting address is not on a page
                boundary, in order to test that we correctly
                handle that case in fault_handling_thread(). */
    char i = 0;
    while (l < len) {
        printf("Write address %p in main(): ", addr + l);
        addr[l] = i++;
        printf("%d\n", addr[l]);
        l += PAGE_SIZE / 2;

        struct uffdio_writeprotect uffdio_wp = {
            .range = {
                .start = (unsigned long) addr,
                .len = len,
            },
            .mode = UFFDIO_WRITEPROTECT_MODE_WP,
        };
        if (ioctl(uffd, UFFDIO_WRITEPROTECT, &uffdio_wp) == -1)
            errExit("ioctl-UFFDIO_WRITEPROTECT");
    }

    exit(EXIT_SUCCESS);
}