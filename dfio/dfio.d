module dfio;

import std.stdio;
import std.string;
import std.format;
import std.exception;
import std.conv;
import std.array;
import core.thread;
import std.container.dlist;
import core.sys.posix.sys.types;
import core.sys.posix.unistd;
import core.sys.linux.epoll;
import core.sync.mutex;
import core.stdc.errno;
import core.atomic;
import BlockingQueue : BlockingQueue, unshared;
import core.sys.posix.stdlib: abort;
import core.sys.posix.fcntl;

Fiber currentFiber; // this is TLS per user thread

shared int managedThreads = 0;
shared int alive; // count of non-terminated Fibers
shared BlockingQueue!Fiber queue;
shared Mutex mtx;

enum int TIMEOUT = 100, MAX_EVENTS = 100;

int checked(int value, const char* msg="unknown place") {
    if (value < 0) {
        perror(msg);
        _exit(value);
    }
    return value;
}

ssize_t checked(ssize_t value, const char* msg="unknown place") {
    if (value < 0) {
        perror(msg);
        abort();
    }
    return value;
}

version (X86) {
    enum int SYS_READ = 0x3;
    int syscall(int ident, int n, int arg1, int arg2)
    {
        int ret;

        synchronized asm
        {
            mov EAX, ident;
            mov EBX, n[EBP];
            mov ECX, arg1[EBP];
            mov EDX, arg2[EBP];
            int 0x80;
            mov ret, EAX;
        }
        return ret;
    }
} else version (X86_64) {
    enum int SYS_READ = 0x0;
    size_t syscall(size_t ident, size_t n, size_t arg1, size_t arg2)
    {
        size_t ret;

        synchronized asm
        {
            mov RAX, ident;
            mov RDI, n[RBP];
            mov RSI, arg1[RBP];
            mov RDX, arg2[RBP];
            syscall;
            mov ret, RAX;
        }
        return ret;
    }
}

extern(C) ssize_t read(int fd, void *buf, size_t count)
{
    writeln("HOOKED WITH MY LIB!"); // TODO: temporary for easy check, remove later

    int flags = fcntl(fd, F_GETFL, 0);
    if (!(flags & O_NONBLOCK)) {
        perror("WARNING: Socket not set in O_NONBLOCK mode!");
        //abort(); //TODO: enforce abort?
    }
    for(;;) {
        ssize_t resp = syscall(SYS_READ, fd, cast(ssize_t) buf, cast(ssize_t) count);
        if (resp == -EWOULDBLOCK || resp == -EAGAIN) {
            add_await(fd, currentFiber, EPOLLIN);
            currentFiber = queue.pop();
            Fiber.yield();
            continue;
        } else return resp;
    }
    // This should never be reached
    return -1337;
}

void runUntilCompletion()
{
    atomicOp!"+="(managedThreads, 1);
    while (alive > 0) {
        //currentFiber = take(queue); // TODO implement take

        currentFiber = queue.pop();
        stderr.writefln("Fiber %x started", cast(void*)currentFiber);
        currentFiber.call();
        if (currentFiber.state == Fiber.State.TERM) {
            stderr.writefln("Fiber %s terminated", cast(void*)currentFiber);
            atomicOp!"-="(alive, 1);
        }
    }
    atomicOp!"-="(managedThreads, 1);
}

void spawn(void delegate() func) {
    auto f = new Fiber(func);
    queue = new shared BlockingQueue!Fiber;
    queue.push(f);
    atomicOp!"+="(alive, 1);
}

shared DescriptorState[] descriptors;
shared int event_loop_fd;

struct AwaitingFiber {
    Fiber fiber;
    int op; // EPOLLIN = reading & EPOLLOUT = writing
}

// list of awaiting fibers
struct DescriptorState {
    AwaitingFiber[] waiters;  // can optimize for 1-element case, more on that later
}

void add_await(int fd, Fiber fiber, int op) {
    mtx.lock();
    (cast(DescriptorState[])descriptors)[fd].waiters ~= AwaitingFiber(currentFiber, op);
    mtx.unlock();
}

void event_add_fd(int fd) { // register new FD
    epoll_event event;
    event.events = EPOLLIN | EPOLLOUT; // TODO: most events that make sense to watch for
    event.data.fd = fd;
    epoll_ctl(event_loop_fd, EPOLL_CTL_ADD, fd, &event).checked("ERROR: failed epoll_ctl add!");
}

void event_remove_fd(int fd) { // TODO: on LibC's close
    epoll_ctl(event_loop_fd, EPOLL_CTL_DEL, fd, null).checked("ERROR: failed epoll_ctl delete!");
}

void startloop(int[] fds)
{
    mtx = cast(shared)new Mutex();
    event_loop_fd = cast(int)epoll_create1(0).checked("ERROR: Failed to create event-loop!");
    ssize_t fdMax = sysconf(_SC_OPEN_MAX).checked;
    descriptors = cast(shared)new DescriptorState[fdMax];

    foreach(f; fds)
        event_add_fd(f);

    auto io = new Thread(&eventloop, 64*1024);
    io.start();
}

void eventloop()
{
    epoll_event[MAX_EVENTS] events;
    while(managedThreads > 0) {

        int r = epoll_wait(event_loop_fd, events.ptr, MAX_EVENTS, TIMEOUT)
            .checked("ERROR: failed epoll_wait");
        stderr.writefln("Passed epoll_wait, r = %d", r);

        for (int n = 0; n < r; n++) {
            int fd = events[n].data.fd;
            mtx.lock();
            auto w = descriptors[fd].waiters;

            //TODO: remove the ones from the waiting list
            size_t j = 0;
            for (size_t i = 0; i<w.length;) {
                auto a = w[i];
                //stderr.writefln("Event %s on fd=%s op=%s waiter=%s", events[n].events, events[n].data.fd, a.op, cast(void*)a.fiber);
                // 3. the trick is read and write are separate, and then there are TODO: exceptions (errors)
                if ((a.op & events[n].events) != 0) {
                    stderr.writeln("HERE!");
                    queue.push(cast(Fiber)(a.fiber));
                    i++;
                }
                else if(i != j) {
                    w[j] = w[i];
                    j++;
                    i++;
                }
            }
            mtx.unlock();
            Thread.yield();
        }
    }
}