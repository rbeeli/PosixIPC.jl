using TestItems

@testitem "shm_exists" begin
    using PosixIPC.SharedMemory

    @test shm_exists("NOT_EXISTING_SHM") == false

    shm = shm_open(
        "for_unit_test_shm_exists",
        oflag=Base.Filesystem.JL_O_CREAT |
              Base.Filesystem.JL_O_RDWR |
              Base.Filesystem.JL_O_TRUNC,
        mode=0o666,
        size=32
    )

    @test shm_exists("for_unit_test_shm_exists") == true

    shm_unlink(shm)
    shm_close(shm)
end

@testitem "SPSCQueue shared memory" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues.SPSC

    buffer_size = 1024 # bytes
    shm_size = buffer_size + SPSC_BUFFER_OFFSET

    shm = shm_open(
        "SPSCQueue_jl_shm_unit_test",
        oflag=Base.Filesystem.JL_O_CREAT |
              Base.Filesystem.JL_O_RDWR |
              Base.Filesystem.JL_O_TRUNC,
        mode=0o666,
        size=shm_size
    )
    storage = SPSCStorage(shm.ptr, shm.size)
    queue = SPSCQueueVar(storage)

    # now destroy shared memory
    shm_unlink(shm)
    shm_close(shm)
end

@testitem "SPSCQueue shared memory reopen" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues
    using PosixIPC.Queues.SPSC

    buf_size = 1024 # bytes
    shm_size = buf_size + SPSC_BUFFER_OFFSET

    shm = shm_open(
        "SPSCQueue_jl_shm_unit_test_reopen"
        ;
        oflag=Base.Filesystem.JL_O_CREAT |
              Base.Filesystem.JL_O_RDWR |
              Base.Filesystem.JL_O_TRUNC,
        mode=0o666,
        size=shm_size,
        verbose=true
    )
    storage = SPSCStorage(shm.ptr, shm.size)
    queue = SPSCQueueVar(storage)

    # push 10 messages
    for i in 1:10
        data = [Float64(i)]
        GC.@preserve data begin
            ptr = reinterpret(Ptr{Float64}, pointer(data))
            @test enqueue!(queue, Message(ptr, 1))
        end
    end

    # pop 3 messages
    for i in 1:3
        msg_view = dequeue_begin!(queue)
        @test !isempty(msg_view)
        dequeue_commit!(queue, msg_view)
    end

    # close shared memory, but keep the queue alive
    shm_close(shm)

    # reopen shared memory
    # works only on Linux (see src/shm.jl for details)
    shm = shm_open(
        "SPSCQueue_jl_shm_unit_test_reopen",
        oflag=Base.Filesystem.JL_O_RDWR,
        mode=0o666,
        verbose=true
    )

    storage = SPSCStorage(shm.ptr)
    println("read_ix: ", unsafe_load(storage.read_ix, :monotonic))
    println("write_ix: ", unsafe_load(storage.write_ix, :monotonic))
    @test unsafe_load(storage.read_ix, :monotonic) == 3 * (8 + 8)
    @test unsafe_load(storage.write_ix, :monotonic) == 10 * (8 + 8)
    @test storage.storage_size == shm_size
    @test buffer_size(storage) == buf_size

    queue = SPSCQueueVar(storage)
    @test can_dequeue(queue)
    @test !isempty(queue)

    # now destroy shared memory
    shm_unlink(shm)
    shm_close(shm)
end
