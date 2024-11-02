using TestItems

@testitem "init on heap memory" begin
    using PosixIPC.Queues.SPSC

    buffer_size = 1024 # bytes
    storage = SPSCStorage(buffer_size)
    queue = SPSCQueueVar(storage)
end

@testitem "enqueue dequeue isempty can_dequeue" begin
    using PosixIPC.Queues
    using PosixIPC.Queues.SPSC

    buffer_size = 1024 # bytes
    storage = SPSCStorage(buffer_size)
    queue = SPSCQueueVar(storage)

    @test isempty(queue)
    @test !can_dequeue(queue)

    # enqueue
    data = [1, 2, 3, 4, 5]
    GC.@preserve data begin
        size_bytes = length(data) * sizeof(eltype(data))
        ptr = reinterpret(Ptr{UInt8}, pointer(data))
        msg = Message(ptr, size_bytes)
        enqueue!(queue, msg)

        @test !isempty(queue)
        @test can_dequeue(queue)

        # dequeue
        msg_view = dequeue_begin!(queue)
        @test msg_view.size == size_bytes
        for i in 1:msg_view.size
            @test unsafe_load(msg_view.data, i) == unsafe_load(ptr, i)
        end
        dequeue_commit!(queue, msg_view)
    end

    @test isempty(queue)
    @test !can_dequeue(queue)
end

@testitem "free SPSCStorage aligned alloc" begin
    using PosixIPC.Queues.SPSC
    
    count = Memory.aligned_alloc_count()
    println("pre GC aligned_alloc_count() = ", count)
    # wrap in function to ensure GC collection
    function work()
        for _ in 1:10
            _ = SPSCStorage(1024)
            println("aligned_alloc_count() = ", Memory.aligned_alloc_count())
        end
    end
    work()
    GC.gc(true)
    println("post GC aligned_alloc_count() = ", Memory.aligned_alloc_count())
    @test Memory.aligned_alloc_count() == count
end
