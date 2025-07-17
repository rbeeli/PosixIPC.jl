# PosixIPC.jl

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![](https://img.shields.io/badge/Version-beta-blue)

This library implements a set of POSIX-compliant inter-process communication (IPC) mechanisms and relevant helper functions in Julia.

## SPSC queue

The Single-Producer Single-Consumer (SPSC) queue allows to push variable-sized binary messages into a queue from one thread, and pop them from another thread.

For inter-process communication, the queue can be used in shared memory.

The queue is lock-free and uses a circular buffer to store the messages and their payloads in a contiguous memory block.

The queue memory can be used directly by the consumer as long as the dequeue-operation hasn't been committed (see `dequeue_commit!`), which allows for zero-copy message passing.

## Publish-Subscribe (PubSub)

The Publish-Subscribe (PubSub) mechanism allows multiple subscribers to receive messages from a single publisher (one-to-many communication, fan-out).
This is implemented using a dedicated SPSC queue for each subscriber. The publisher enqueues messages into all subscriber SPSC queues sequentially.

## Performance

On a 12th Gen Intel(R) Core(TM) i9-12900K running Ubuntu 22.04 x64, the SPSC queue can:

- enqueue and dequeue way above 200 million 8-byte messages per second
- achieve latencies of < 100 nanoseconds in the non-contended case (producer slower than consumer, consumer busy spinning)

The queue buffer memory can be allocated on the heap, or in shared memory (see `SPSCStorage`).

## API

### SPSCQueue

The queue is implemented in the `SPSCQueue` module and provides the following functions:

```julia
using PosixIPC.Queues
using PosixIPC.Queues.SPSC

# constructor: Create storage memory on heap
SPSCStorage(storage_size::Integer)

# constructor: Create new storage from `Ptr{UInt8}` pointer
SPSCStorage(ptr::Ptr{T}, storage_size::Integer; finalizer_fn::Function)

# constructor: Opens existing storage buffer from an `UInt8` pointer
SPSCStorage(ptr::Ptr{T}; finalizer_fn::Function)

# constructor: Create an instance of a Single-Producer Single-Consumer (SPSC) queue with variable-sized message buffer.
SPSCQueueVar(storage::SPSCStorage)

# Enqueues a message in the queue. Returns `true` if successful, `false` if the queue is full.
enqueue!(queue::SPSCQueueVar, msg::Message)::Bool

# Reads the next message from the queue.
# Returns a message view with `size = 0` if the queue is empty (`SPSC_MESSAGE_VIEW_EMPTY`).
# Call `isempty(msg)` to check if a message was dequeued successfully.
# The reader only advances after calling `dequeue_commit!`, this allows to use the
# message view without copying the data to another buffer between `dequeue_begin!` and `dequeue_commit!`.
# Failing to call `dequeue_commit!` is allowed, but means the reader will not advance.
dequeue_begin!(queue::SPSCQueueVar)::MessageView

# Moves the reader index to the next message in the queue.
# Call this after processing a message returned by `dequeue_begin!`.
# The message view is no longer valid after this call.
dequeue_commit!(queue::SPSCQueueVar, msg_view::MessageView)::Nothing

# Returns `true` if the message view is empty (size is 0), implying that the queue is empty.
isempty(msg_view::MessageView)::Bool

# Returns `true` if the SPSC queue is empty.
# Does not dequeue any messages (read-only operation).
# There is no guarantee that the queue is still empty after this function returns,
# as the writer might have enqueued a message immediately after the check.
isempty(queue::SPSCQueueVar)::Bool

# Returns `false` if the SPSC queue is empty.
# Does not dequeue any messages (read-only operation).
# To be used by consumer thread only due to memory order optimization.
can_dequeue(queue::SPSCQueueVar)::Bool
```

### PubSub

The Publish-Subscribe (PubSub) mechanism is implemented in the `PubSub` module and provides the following functions:

```julia
using PosixIPC.SharedMemory
using PosixIPC.Queues
using PosixIPC.Queues.PubSub

PubSubConfig(
    shm_name::String,
    storage_size_bytes::Int
    ;
    queue_full_policy::QueueFullPolicy.T,
    log_message_drop::Bool=true
)

# Creates a new instance of a Publish-Subscribe (PubSub) hub.
PubSubHub()

# Synchronizes list of PubSub configurations with the PubSubHub.
# This function should be called by the publisher to update the list of subscribers
# and their SPSC queues.
sync_configs!(ps::PubSubHub, configs::Vector{PubSubConfig})::Nothing

# Publishes a message to all subscribers and enqueues it in their SPSC queues.
publish!(ps::PubSubHub, val::Message)::Bool
```

### SharedMemory

The `SharedMemory` module provides helper functions to work with shared memory on POSIX-compliant systems.

```julia
using PosixIPC.SharedMemory

# Open or create a shared memory object.
shm_open(
    shm_name::String
    ;
    shm_flags=Base.Filesystem.JL_O_RDWR,
    shm_mode=0o666,
    size=-1,
    verbose::Bool=false
)::PosixSharedMemory

# Delete a shared memory object (incl. the data).
shm_unlink(shm::PosixSharedMemory)::Nothing

# Close file descriptor of shared memory object.
shm_close(shm::PosixSharedMemory)::Nothing
```

### Memory

The `Memory` module provides helper functions to work with aligned memory.

```julia
using PosixIPC.Memory

# Allocate aligned memory block.
aligned_alloc(alignment::Integer, size::Integer)::Ptr{Cvoid}

# Free aligned memory block.
aligned_free(ptr::Ptr{UInt8})::Nothing
```

## Examples

The following example creates a SPSC queue with a fixed-size ring buffer of 100,000 bytes.
The queue itself allows to push and pop variable-sized messages. We send 1,000,000 messages from the producer to the consumer, and print the status every 10,000 messages.

### SPSCQueue

```julia
using ThreadPinning
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
    storage = SPSCStorage(buffer_size)

    # create variable-element size SPSC queue
    queue = SPSCQueueVar(storage)

    # spawn producer and consumer threads, pin them to cores 3 and 5
    iterations = 1_000_000
    p_thread = ThreadPinning.@spawnat 3 producer(queue, iterations) # 1-based indexing
    c_thread = ThreadPinning.@spawnat 5 consumer(queue, iterations) # 1-based indexing

    wait(p_thread)
    wait(c_thread)
end

run()
```

### Shared memory

The queue storage can be allocated in shared memory, which allows to use the queue for inter-process communication.
Instead of using `SPSCStorage(buffer_size)`, use `SPSCStorage(ptr, storage_size; finalizer_fn)` to create the storage from a pointer to shared memory.

`SPSCStorage` can work with arbitrary `Ptr{T}` types.
It is the user's responsibility to manage the shared memory and provide the correct pointer and size.
Optionally, a finalizer function can be provided to clean up the shared memory when the storage is no longer needed.

Example of creating a `SPSCStorage` object in shared memory for a SPSC queue:

```julia
using PosixIPC.SharedMemory
using PosixIPC.Queues.SPSC

buffer_size = 100_000 # bytes
shm_size = buffer_size + SPSC_BUFFER_OFFSET

# works only on Linux (see test/shm.jl for details)
shm = shm_open(
    "spscqueue_jl_shared_memory",
    oflag=Base.Filesystem.JL_O_CREAT |
          Base.Filesystem.JL_O_RDWR |
          Base.Filesystem.JL_O_TRUNC,
    mode=0o666,
    size=shm_size
)
storage = SPSCStorage(shm.ptr, shm.size)
```

See [examples/shared_memory.jl](examples/shared_memory.jl) for the example file.
