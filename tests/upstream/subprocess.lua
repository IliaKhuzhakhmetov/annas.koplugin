-- Test fixture: KOReader's POSIX subprocess functions, with minimal FFI declarations.
-- Source: koreader/koreader-base ffi/util.lua (ab0d8e2a2cfbbd3b57f7975077b0b124eac8dcd2).
local ffi = require("ffi")
ffi.cdef[[
typedef int pid_t;
int pipe(int *);
pid_t fork(void);
void _exit(int);
int setpgid(pid_t, pid_t);
pid_t getpid(void);
int close(int);
int setpriority(int, unsigned int, int);
pid_t waitpid(pid_t, int *, int);
int kill(pid_t, int);
int ioctl(int, unsigned long, ...);
long read(int, void *, unsigned long);
long write(int, const void *, unsigned long);
int usleep(unsigned int);
int fileno(void *);
char *strerror(int);
struct sched_param { int sched_priority; };
int sched_setscheduler(pid_t, int, const struct sched_param *);
enum { PRIO_PROCESS = 0, WNOHANG = 1, SCHED_BATCH = 3 };
]]
ffi.cdef(ffi.os == "OSX" and "enum { FIONREAD = 0x4004667f };" or "enum { FIONREAD = 0x541b };")
local C = ffi.C
local posix = { strerror = function() return ffi.string(C.strerror(ffi.errno())) end }
local logger = require("logger")
local util = {}
local _run_before_fork_funcs, _run_after_fork_parent_funcs, _run_in_subprocess_after_fork_funcs = {}, {}, {}

function util.runInSubProcess(func, with_pipe, double_fork)
    local parent_read_fd, parent_write_fd
    local child_read_fd, child_write_fd
    if with_pipe then
        local pipe = ffi.new('int[2]', {-1, -1})
        if C.pipe(pipe) ~= 0 then -- failed creating pipe !
            return false, "failed creating pipe: "..posix.strerror()
        end
        parent_read_fd, child_write_fd = pipe[0], pipe[1]
        if with_pipe == 'bidi' then
            if C.pipe(pipe) ~= 0 then -- failed creating pipe !
                return false, "failed creating pipe: "..posix.strerror()
            end
            parent_write_fd, child_read_fd = pipe[1], pipe[0]
        end
    end
    -- Run before-fork hooks in the parent.  Callers (e.g. the SDL backend) use
    -- this to stop subsystem threads that may hold glibc malloc arena locks.
    -- If such a thread is mid-malloc when fork() is called, glibc's atfork
    -- prepare handler will block waiting for the lock, freezing the UI.
    for _, f in pairs(_run_before_fork_funcs) do
        f()
    end
    local pid = C.fork()
    -- Run after-fork-parent hooks immediately, before any error checking, so
    -- that subsystems stopped above are always restarted.
    if pid ~= 0 then
        for _, f in pairs(_run_after_fork_parent_funcs) do
            f()
        end
    end
    if pid == 0 then -- child process
        for _, f in pairs(_run_in_subprocess_after_fork_funcs) do
            f()
        end
        if double_fork then
            pid = C.fork()
            if pid ~= 0 then
                -- Parent side of the outer fork, we don't need it anymore, so just exit.
                C._exit((pid < 0) and 1 or 0)
            end
            -- pid == 0 -> inner child :)
        end
        -- We need to wrap it with pcall: otherwise, if we were in a
        -- subroutine, the error would just abort the coroutine, bypassing
        -- our os.exit(0), and this subprocess would be a working 2nd instance
        -- of KOReader (with libraries or drivers probably getting messed up).
        local ok, err = xpcall(function()
            -- Give the child its own process group, so we can kill(-pid) it
            -- to have all its own children killed too (otherwise, parent
            -- process would kill the child, the child's children would
            -- be adopted by init, but parent would still have
            -- util.isSubProcessDone() returning false until all the child's
            -- children are done.
            C.setpgid(0, 0)
            -- close our duplicate parent fds
            if parent_read_fd then
                C.close(parent_read_fd)
            end
            if parent_write_fd then
                C.close(parent_write_fd)
            end

            -- As the name imply, this is a non-interactive background task.
            if ffi.os == "Linux" then
                -- On Linux, schedule it accordingly.
                local param = ffi.new("struct sched_param")
                C.sched_setscheduler(0, C.SCHED_BATCH, param)
            end
            -- And nice it at lower priority, too (unlike the above call, this is POSIX).
            C.setpriority(C.PRIO_PROCESS, 0, 5)

            -- Just run the provided lua code object in this new process,
            -- and exit immediatly (so we do not release drivers and
            -- resources still used by parent process)
            -- We pass child pid to func, which can serve as a key
            -- to communicate with parent process.
            -- We pass child_write_fd (if with_pipe) so 'func' can write to it
            pid = C.getpid()
            func(pid, child_write_fd, child_read_fd)
        end, debug.traceback)
        if not ok then
            print("error in subprocess:", err)
        end
        C._exit(0)
    end
    -- parent/main process
    if pid < 0 then -- on failure, fork() returns -1
        return false, "fork failed: "..posix.strerror()
    end
    -- If we double-fork, reap the outer fork now, since its only purpose is fork -> _exit
    if double_fork then
        local status = ffi.new('int[1]')
        local ret = C.waitpid(pid, status, 0)
        -- Returns pid on success, -1 on failure
        if ret < 0 then
            return false, "double fork failed: "..posix.strerror()
        end
    end
    -- close our duplicate child fds
    if child_read_fd then
        C.close(child_read_fd)
    end
    if child_write_fd then
        C.close(child_write_fd)
    end
    return pid, parent_read_fd, parent_write_fd
end

--- Collect subprocess so it does not become a zombie.
-- This does not block, unless `wait` is `true`.
-- Returns true if process was collected or has already exited, false if process is still running.
function util.isSubProcessDone(pid, wait)
    local status = ffi.new('int[1]')
    local ret = C.waitpid(pid, status, wait and 0 or C.WNOHANG)
    -- status = tonumber(status[0])
    -- If still running: ret = 0 , status = 0
    -- If exited: ret = pid , status = 0 or 9 if killed
    -- If no more running: ret = -1 , status = 0
    if ret == pid or ret == -1 then
        return true
    end
    return false
end

--- Terminate subprocess pid by sending SIGKILL
function util.terminateSubProcess(pid)
    local done = util.isSubProcessDone(pid)
    if not done then
        -- We kill with signal 9/SIGKILL, which may be violent, but ensures
        -- that it is terminated (a process may catch or ignore SIGTERM)
        -- If we used setpgid(0,0) above, we can kill the process group
        -- instead, by just using -pid
        -- C.kill(pid, 9)
        C.kill(-pid, 9)
        -- Process will still have to be collected with calls to
        -- util.isSubProcessDone(), which may still return false for
        -- some small amount of time after our kill()
    end
end

--- Returns the length of data that can be read immediately without blocking
--
-- Accepts a low-level file descriptor, or a higher level lua file object
-- returns 0 if not readable yet, otherwise len of available data
-- returns nil when unsupported: caller may read (with possible blocking)
--
-- Caveats with pipes: returns 0 too if other side of pipe has exited
-- without writing anything
function util.getNonBlockingReadSize(fd_or_luafile)
    local fileno
    if type(fd_or_luafile) == "number" then -- low-level fd
        fileno = fd_or_luafile
    else -- lua file object
        fileno = C.fileno(fd_or_luafile)
    end
    local available = ffi.new('int[1]')
    local ok = C.ioctl(fileno, C.FIONREAD, available)
    if ok ~= 0 then -- ioctl failed, not supported
        print("C.ioctl(…, FIONREAD, …) failed:", posix.strerror())
        return
    end
    available = tonumber(available[0])
    return available
end

--- Write data to file descriptor, and optionally close it when done
--
-- May block if data is large until the other end has read it.
-- If data fits into kernel pipe buffer, it can return before the
-- other end has started reading it.
function util.writeToFD(fd, data, close_fd)
    local size = #data
    local ptr = ffi.cast("uint8_t *", data)
    -- print("writing to fd")
    local bytes_written = C.write(fd, ptr, size)
    -- print("done writing to fd")
    local success = bytes_written == size
    if close_fd then
        C.close(fd)
        -- print("write fd closed")
    end
    return success
end

function util.readAllFromFD(fd)
    local chunksize = 8192
    local buffer = ffi.new('char[?]', chunksize, {0})
    local data = {}
    while true do
        -- print("reading from fd")
        local bytes_read = tonumber(C.read(fd, ffi.cast('void*', buffer), chunksize))
        if bytes_read < 0 then
            print("readAllFromFD() error: "..posix.strerror())
            break
        elseif bytes_read == 0 then -- EOF, no more data to read
            break
        else
            table.insert(data, ffi.string(buffer, bytes_read))
        end
    end
    C.close(fd)
    -- print("read fd closed")
    return table.concat(data)
end


return util

