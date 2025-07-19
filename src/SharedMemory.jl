module SharedMemory

using Base.Filesystem
using Base.Libc: strerror
using Base: unsafe_convert

const PROT_READ = 0x01
const PROT_WRITE = 0x02
const MAP_SHARED = 0x01

const __off64_t = Clong
const __mode_t = UInt32

"""
Represents a POSIX shared memory object.

Note that the shared memory object is not unlinked when the object is garbage collected,
so it is the responsibility of the user to unlink the shared memory object when it is no longer needed and the data can be deleted.

Furthermore, you MUST keep a reference to this object for as long as the shared memory object is being used in order to prevent it from being garbage collected.
"""
mutable struct PosixSharedMemory
    name::String
    fd::File
    ptr::Ptr{UInt8}
    size::Int

    function PosixSharedMemory(name::String, fd::File, ptr::Ptr{UInt8}, size::Int)
        obj = new(name, fd, ptr, size)
        finalizer(shm -> close(shm.fd), obj)
    end
end

"""
Opens or creates a POSIX shared memory object.

# Returns
`PosixSharedMemory` object representing the shared memory object.

# Errors
Throws an error if shared memory object creation or opening fails.

# Examples

## Creating new shared memory region

```julia
shm = shm_open(
    "spscqueue_jl_shared_memory"
    ;
    oflag=Base.Filesystem.JL_O_CREAT |
        Base.Filesystem.JL_O_RDWR |
        Base.Filesystem.JL_O_TRUNC,
    mode=0o666,
    size=shm_size
)
```

## Opening existing shared memory region

```julia
shm = shm_open(
    "spscqueue_jl_shared_memory",
    oflag=Base.Filesystem.JL_O_RDWR,
    mode=0o666,
    size=-1
)
```

# References
https://pubs.opengroup.org/onlinepubs/007904875/functions/shm_open.html
"""
function shm_open(
    name::String; oflag=Base.Filesystem.JL_O_RDWR, mode=0o666, size=-1, verbose::Bool=false
)::PosixSharedMemory
    # file descriptor
    fd_handle = @ccall shm_open(name::Cstring, oflag::Cint, mode::__mode_t)::Cint
    if fd_handle == -1
        error("Shared memory '$name' shm_open failed: " * Libc.strerror(Libc.errno()))
    end

    fd = File(RawFD(fd_handle))

    if oflag & JL_O_CREAT != 0
        verbose && println("Creating shared memory '$name' with size $size")

        if size <= 0
            error(
                "Shared memory '$name' size must be specified when creating with JL_O_CREAT flag."
            )
        end

        # set size of shared memory region
        rc = @ccall ftruncate(fd.handle::Cint, size::Csize_t)::Int
        if rc == -1
            close(fd)
            error("Shared memory '$name' shm_open ftruncate failed: " * Libc.strerror(Libc.errno()))
        end
    else
        verbose && println("Opening shared memory '$name'")

        # read size of existing shared memory region
        try
            s = stat(fd)
            size = s.size
            println("Shared memory '$name' of size $size opened")
        catch e
            close(fd)
            error("Shared memory '$name' shm_open stat failed. Error: $e")
        end
    end

    # map shared memory region
    prot::Cint = PROT_READ | PROT_WRITE
    flags::Cint = MAP_SHARED
    c_ptr = @ccall mmap(
        C_NULL::Ptr{Cvoid}, size::Csize_t, prot::Cint, flags::Cint, fd.handle::Cint, 0::__off64_t
    )::Ptr{Cvoid}
    if reinterpret(Int, c_ptr) == -1
        close(fd)
        error("Shared memory '$name' shm_open mmap failed: " * Libc.strerror(Libc.errno()))
    end

    ptr = reinterpret(Ptr{UInt8}, c_ptr)

    PosixSharedMemory(name, fd, ptr, Int(size))
end

"""
Checks if a POSIX shared memory object with the given name exists.
"""
function shm_exists(name::String)::Bool
    oflag = Base.Filesystem.JL_O_RDONLY
    mode = 0o0
    shm_fd = @ccall shm_open(name::Cstring, oflag::Cint, mode::__mode_t)::Cint

    if shm_fd == -1
        err = Libc.errno()
        if err == Libc.ENOENT
            return false
        end
        error("shm_exists error: $(Libc.strerror(err))")
    end

    if ccall(:close, Int, (Cint,), shm_fd) == -1
        error("shm_exists close failed: $(Libc.strerror(Libc.errno()))")
    end

    return true
end

"""
The operation of `shm_unlink()` is analogous to `unlink()`:
it removes a shared memory object name, and, once all processes have unmapped the object, de-allocates and destroys the contents of the associated memory region.
After a successful `shm_unlink()`, attempts to `shm_open()` an object with the same name will fail (unless `O_CREAT` was specified, in which case a new, distinct object is created).

# Errors
Throws an error if the `shm_unlink()` call fails.

# References
https://linux.die.net/man/3/shm_unlink
"""
function shm_unlink(shm::PosixSharedMemory)::Nothing
    if ccall(:shm_unlink, Int, (Ptr{UInt8},), shm.name) == -1
        error("shm_unlink failed for name=$(shm.name): " * Libc.strerror(Libc.errno()))
    end
end

"""
Closes shared memory region and unmaps it from the process address space.
This function does not unlink the shared memory region, so it can be opened again and the data will be preserved.

The implementation is based on the C function `close()`.

# Errors
Throws an error if the `close()` call fails.

# References
https://linux.die.net/man/3/close
"""
function shm_close(shm::PosixSharedMemory)::Nothing
    close(shm.fd)
end

export PosixSharedMemory, shm_open, shm_exists, shm_unlink, shm_close

end # module
