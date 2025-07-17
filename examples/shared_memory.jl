using ThreadPinning
using PosixIPC.SharedMemory
using PosixIPC.Queues
using PosixIPC.Queues.SPSC

function producer(queue::SPSCQueueVar, iterations::Int64)
    println("producer started")

    # 8 bytes message
    size = 8
    data = Int64[0]
    GC.@preserve data begin
        data_ptr = pointer(data)
        msg = Message(data_ptr, size)
        for counter in 1:iterations
            # store counter value in message
            unsafe_store!(data_ptr, counter)

            # enqueue message
            while !enqueue!(queue, msg)
                # queue full - busy wait
            end

            # print status
            if counter % 10_000 == 0
                println("> sent $counter")
            end
        end
    end

    println("producer done")
end

function consumer(queue::SPSCQueueVar, iterations::Int64)
    println("consumer started")

    counter = 0
    while counter < iterations
        msg_view = dequeue_begin!(queue)
        if !isempty(msg_view)
            # get counter value from message
            counter = unsafe_load(reinterpret(Ptr{Int64}, msg_view.data))

            # commit message
            dequeue_commit!(queue, msg_view)

            # print status
            if counter % 10_000 == 0
                println("< received $counter")
            end
        end
    end

    println("consumer done")
end

function run()
    buffer_size = 100_000 # bytes
    shm_size = buffer_size + SPSC_BUFFER_OFFSET

    shm = shm_open(
        "spscqueue_jl_shared_memory",
        oflag=Base.Filesystem.JL_O_CREAT |
              Base.Filesystem.JL_O_RDWR |
              Base.Filesystem.JL_O_TRUNC,
        mode=0o666,
        size=shm_size
    )
    storage = SPSCStorage(shm.ptr, shm.size)

    # create variable-element size SPSC queue
    queue = SPSCQueueVar(storage)

    # spawn producer and consumer threads, pin them to cores 3 and 5
    iterations = 1_000_000
    p_thread = ThreadPinning.@spawnat 3 producer(queue, iterations) # 1-based indexing
    c_thread = ThreadPinning.@spawnat 5 consumer(queue, iterations) # 1-based indexing

    wait(p_thread)
    wait(c_thread)

    # destroy shared memory object (deletes it from the system)
    shm_unlink(shm)

    # close file descriptor
    shm_close(shm)
end

run()
