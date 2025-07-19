mutable struct PubSubConfig
    shm_name::String
    storage_size_bytes::Int
    queue_full_policy::QueueFullPolicy.T
    log_message_drop::Bool

    # Constructor with default values
    function PubSubConfig(
        shm_name::String,
        storage_size_bytes::Int;
        queue_full_policy::QueueFullPolicy.T,
        log_message_drop::Bool=true,
    )
        new(shm_name, storage_size_bytes, queue_full_policy, log_message_drop)
    end
end
