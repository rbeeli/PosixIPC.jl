import ...Queues
using ...Queues: Message
using ...Queues: enqueue!, isempty, publish!

struct PubSubHubChange
    addition::Union{Nothing,Publisher}
    removal::Union{Nothing,String}
end

mutable struct PubSubHub
    publishers::Vector{Publisher}
    change_queue::Vector{PubSubHubChange}
    lock_obj::ReentrantLock

    function PubSubHub()
        new(Publisher[], PubSubHubChange[], ReentrantLock())
    end
end

"""
Synchronizes the publishers with the provided configurations.
"""
function sync_configs!(ps::PubSubHub, configs::Vector{PubSubConfig})::Nothing
    lock(ps.lock_obj) do
        # Remove existing publishers not in config anymore
        for sub in ps.publishers
            found = any(cfg -> sub.config.shm_name == cfg.shm_name, configs)
            if !found
                change = PubSubHubChange(nothing, sub.config.shm_name)
                push!(ps.change_queue, change)
            end
        end

        # Add new subscribers if they don't exist yet
        for cfg in configs
            exists = any(sub -> sub.config.shm_name == cfg.shm_name, ps.publishers)
            if !exists
                res = Publisher(cfg)
                change = PubSubHubChange(res, nothing)
                push!(ps.change_queue, change)
            end
        end

        _apply_changes!(ps)
    end
end

"""
Publishes a message to all subscribers.
Only one thread and the same thread is allowed to call this function.
"""
function Queues.publish!(ps::PubSubHub, val::Message)::Bool
    lock(ps.lock_obj) do
        published = true

        for publisher in ps.publishers
            publish!(publisher, val)  # drops messages if queue is full
            # published &= publish!(publisher, val)  # drops messages if queue is full

            # // bool success = sub->publish(val);
            # // if (!success)
            # // {
            # //     auto& cfg = sub->config();

            # //     // check for policy DROP_NEWEST
            # //     assert(cfg.queue_full_policy == QueueFullPolicy::DROP_NEWEST && "Not implemented");
            # //     ++sub->drop_count;

            # //     // queue full - drop newest incoming messages
            # //     if (cfg.log_message_drop)
            # //     {
            # //         auto drop_time = chrono::clock();
            # //         if (drop_time - sub->last_drop_time > std::chrono::seconds(1))
            # //         {
            # //             std::cout << fmt::format(
            # //                              "PubSub: drop msg for '{}', queue full. This is the {}-th "
            # //                              "message dropped",
            # //                              cfg.shm_name,
            # //                              sub->drop_count
            # //                          )
            # //                       << "\n";
            # //             sub->last_drop_time = drop_time;
            # //         }
            # //     }

            # //     // consider unsubscribing clients as alternative to dropping messages
            # // }
        end

        published
    end
end

"""
Applies a single change to the publisher list.
"""
function _apply_change!(ps::PubSubHub, change::PubSubHubChange)::Nothing
    if !isnothing(change.addition)
        push!(ps.publishers, change.addition)
    elseif !isnothing(change.removal)
        idx = findfirst(sub -> sub.config.shm_name == change.removal, ps.publishers)
        if !isnothing(idx)
            @info "Unsubscribing: $(change.removal)"
            deleteat!(ps.publishers, idx)
        end
    end
    nothing
end

"""
Applies all pending changes in the change queue.
"""
function _apply_changes!(ps::PubSubHub)::Nothing
    for change in ps.change_queue
        _apply_change!(ps, change)
    end
    empty!(ps.change_queue)
    nothing
end
