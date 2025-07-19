using ...SharedMemory: PosixSharedMemory, shm_open, shm_exists
import ...Queues
using ...Queues: Message
using ...Queues: enqueue!, isempty, publish!
import ..SPSC
import ..SPSC: SPSCStorage, SPSCQueueVar

mutable struct Publisher
    config::PubSubConfig
    shm::PosixSharedMemory
    queue::SPSCQueueVar  # resides in shared memory
    last_drop_time::Float64  # time point of last drop in seconds
    drop_count::UInt64

    function Publisher(config::PubSubConfig, shm::PosixSharedMemory, queue::SPSCQueueVar)
        new(
            config,
            shm,
            queue,
            0, # last_drop_time
            0, # drop_count
        )
    end

    function Publisher(config::PubSubConfig)
        # shared memory (try to open, if not exists or size mismatch, create new one)
        shm::Union{PosixSharedMemory,Nothing} = nothing

        recreate::Bool = false
        if shm_exists(config.shm_name)
            try
                shm = shm_open(
                    config.shm_name;
                    oflag=Base.Filesystem.JL_O_RDWR,
                    mode=0o666,
                    size=config.storage_size_bytes,
                    verbose=true,
                )

                # Check if size matches
                if config.storage_size_bytes != shm.size
                    @warn "Shared memory [$(config.shm_name)] size mismatch, expected $(config.storage_size_bytes) bytes, got $(shm.size) bytes, recreating..."
                    recreate = true
                end
            catch e
                error("Failed to open shared memory [$(config.shm_name)] for PubSub Publisher: $e")
            end
        else
            # Flag to create new shared memory if it does not exist
            recreate = true
            @info "Shared memory [$(config.shm_name)] does not exist, creating..."
        end

        # Recreate shared memory if necessary
        if recreate
            try
                shm = shm_open(
                    config.shm_name;
                    oflag=Base.Filesystem.JL_O_CREAT |
                          Base.Filesystem.JL_O_RDWR |
                          Base.Filesystem.JL_O_TRUNC,
                    mode=0o666,
                    size=config.storage_size_bytes,
                    verbose=true,
                )
            catch e
                error(
                    "Failed to create shared memory [$(config.shm_name)] for PubSub Publisher: $e"
                )
            end
        end

        # Initialize queue in shared memory
        if recreate
            # Calls constructor
            storage = SPSCStorage(shm.ptr, shm.size)
        else
            # Already exists, just get the pointer
            storage = SPSCStorage(shm.ptr)
        end
        queue = SPSCQueueVar(storage)

        @info "Publisher created in shared memory [$(config.shm_name)] with size $(shm.size) bytes"

        Publisher(config, shm, queue)
    end
end

# Queue operations
@inline Base.isempty(s::Publisher) = isempty(s.queue)

@inline Queues.publish!(s::Publisher, message::Message) = enqueue!(s.queue, message)
