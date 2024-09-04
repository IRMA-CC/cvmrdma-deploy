#include <err.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/eventfd.h>
#include <sys/types.h>
#include <unistd.h>

int
main(int argc, char *argv[])
{
    int       efd;
    uint64_t  u;
    ssize_t   s;


    efd = eventfd(0, 0);
    if (efd == -1)
        err(EXIT_FAILURE, "eventfd");

    void* addr = malloc(1000);
    printf("addr: %p\n", addr);
    u = (uintptr_t)addr;


    s = write(efd, &u, sizeof(uint64_t));
    if (s != sizeof(uint64_t))
        err(EXIT_FAILURE, "write");
    

    printf("Parent about to read\n");
    s = read(efd, &u, sizeof(uint64_t));
    if (s != sizeof(uint64_t))
        err(EXIT_FAILURE, "read");
    printf("Parent read %"PRIu64" (%#"PRIx64") from efd %p\n", u, u, (void *)u);


    return (EXIT_SUCCESS);
}