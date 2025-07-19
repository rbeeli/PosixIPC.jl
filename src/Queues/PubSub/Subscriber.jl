using ...SharedMemory: PosixSharedMemory, shm_open, shm_exists
import ...Queues
using ...Queues: MessageView
using ...Queues: can_dequeue, dequeue_begin!, dequeue_commit!, isempty
import ..SPSC
import ..SPSC: SPSCStorage, SPSCQueueVar

mutable struct Subscriber
    config::PubSubConfig
    shm::PosixSharedMemory
    queue::SPSCQueueVar  # resides in shared memory

    function Subscriber(config::PubSubConfig, shm::PosixSharedMemory, queue::SPSCQueueVar)
        new(config, shm, queue)
    end

    function Subscriber(config::PubSubConfig)
        if !shm_exists(config.shm_name)
            throw(
                ArgumentError(
                    "Cannot create PubSub subscriber, shared memory [$(config.shm_name)] does not exist.",
                ),
            )
        end

        # Open existing shared memory
        shm = shm_open(
            config.shm_name;
            oflag=Base.Filesystem.JL_O_RDWR,
            mode=0o666,
            size=config.storage_size_bytes,
            verbose=true,
        )

        # Check if size matches
        if config.storage_size_bytes != shm.size
            throw(
                ArgumentError(
                    "Shared memory [$(config.shm_name)] size mismatch, expected $(config.storage_size_bytes), got $(shm.size).",
                ),
            )
        end

        # Initialize queue in shared memory
        storage = SPSCStorage(shm.ptr)
        queue = SPSCQueueVar(storage)

        @info "Subscriber created using shared memory [$(config.shm_name)] with size $(shm.size) bytes."

        new(config, shm, queue)
    end
end

# Queue operations
@inline Queues.dequeue_commit!(s::Subscriber, message::MessageView) =
    dequeue_commit!(s.queue, message)

@inline Queues.dequeue_begin!(s::Subscriber) = dequeue_begin!(s.queue)

@inline Base.isempty(s::Subscriber) = isempty(s.queue)

@inline Queues.can_dequeue(s::Subscriber) = can_dequeue(s.queue)
