using TestItems

@testitem "Publisher (create new)" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues
    using PosixIPC.Queues.PubSub

    # create publisher
    config = PubSubConfig(
        "_unit_test_PubSub_Publisher",
        1000;
        queue_full_policy=QueueFullPolicy.DROP_NEWEST,
        log_message_drop=true,
    )
    publisher = Publisher(config)

    @test publisher.config == config
    @test publisher.last_drop_time == 0
    @test publisher.drop_count == 0
    @test isempty(publisher)

    shm_unlink(publisher.shm)
    shm_close(publisher.shm)
end

@testitem "Publisher (existing)" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues
    using PosixIPC.Queues.PubSub
    import PosixIPC.Queues.SPSC: SPSCStorage

    # create shared memory
    shm = shm_open(
        "_unit_test_PubSub_Subscriber";
        oflag=Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_TRUNC,
        mode=0o666,
        size=1000,
    )

    # initialize SPSCStorage
    function init_storage()
        SPSCStorage(shm.ptr, shm.size)
        nothing
    end
    init_storage()

    # create publisher
    config = PubSubConfig(
        shm.name, shm.size; queue_full_policy=QueueFullPolicy.DROP_NEWEST, log_message_drop=true
    )
    publisher = Publisher(config)

    @test publisher.config == config
    @test publisher.last_drop_time == 0
    @test publisher.drop_count == 0
    @test isempty(publisher)

    shm_unlink(publisher.shm)
    shm_close(publisher.shm)
end

@testitem "Subscriber (create raw shared memory)" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues
    using PosixIPC.Queues.PubSub
    import PosixIPC.Queues.SPSC: SPSCStorage

    # create shared memory
    shm = shm_open(
        "_unit_test_PubSub_Subscriber";
        oflag=Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_TRUNC,
        mode=0o666,
        size=1000,
    )

    # initialize SPSCStorage
    function init_storage()
        SPSCStorage(shm.ptr, shm.size)
        nothing
    end
    init_storage()

    # create subscriber
    config = PubSubConfig(
        shm.name, shm.size; queue_full_policy=QueueFullPolicy.DROP_NEWEST, log_message_drop=true
    )
    subscriber = Subscriber(config)

    @test subscriber.config == config
    @test isempty(subscriber)
    @test !can_dequeue(subscriber)

    shm_unlink(shm)
    shm_close(shm)
end

@testitem "Publisher & Subscriber" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues
    using PosixIPC.Queues.PubSub

    config = PubSubConfig(
        "_unit_test_PubSub_Publisher_Subscriber",
        1000;
        queue_full_policy=QueueFullPolicy.DROP_NEWEST,
        log_message_drop=true,
    )

    publisher = Publisher(config)
    subscriber = Subscriber(config)

    # 8 bytes message
    size = 8
    data = Int64[99]
    GC.@preserve data begin
        data_ptr = pointer(data)
        msg = Message(data_ptr, size)
        publish!(publisher, msg)
    end

    @test !isempty(subscriber)
    @test can_dequeue(subscriber)
    msg_view = dequeue_begin!(subscriber)
    @test !isempty(msg_view)
    @test msg_view.size == size

    # get value from message
    value = unsafe_load(reinterpret(Ptr{Int64}, msg_view.data))
    @test value == 99

    dequeue_commit!(subscriber, msg_view)

    @test isempty(subscriber)
    @test !can_dequeue(subscriber)

    shm_unlink(publisher.shm)
    shm_close(publisher.shm)
    shm_close(subscriber.shm)
end

@testitem "PubSubHub" begin
    using PosixIPC.SharedMemory
    using PosixIPC.Queues
    using PosixIPC.Queues.PubSub

    config1 = PubSubConfig(
        "_unit_test_PubSubHub1",
        1000;
        queue_full_policy=QueueFullPolicy.DROP_NEWEST,
        log_message_drop=true,
    )

    config2 = PubSubConfig(
        "_unit_test_PubSubHub2",
        1000;
        queue_full_policy=QueueFullPolicy.DROP_NEWEST,
        log_message_drop=true,
    )

    pub_sub = PubSubHub()
    sync_configs!(pub_sub, [config1, config2])

    @test length(pub_sub.publishers) == 2
    @test length(pub_sub.change_queue) == 0
    @test pub_sub.publishers[1].config == config1
    @test pub_sub.publishers[2].config == config2

    # 8 bytes message
    size = 8
    data = Int64[99]
    GC.@preserve data begin
        data_ptr = pointer(data)
        msg = Message(data_ptr, size)
        @test publish!(pub_sub, msg)
    end

    sub1 = Subscriber(config1)
    sub2 = Subscriber(config2)

    @test !isempty(sub1)
    @test !isempty(sub2)
    @test can_dequeue(sub1)
    @test can_dequeue(sub2)

    begin
        msg_view = dequeue_begin!(sub1)
        @test !isempty(msg_view)
        @test msg_view.size == size

        # get value from message
        value = unsafe_load(reinterpret(Ptr{Int64}, msg_view.data))
        @test value == 99

        dequeue_commit!(sub1, msg_view)
    end

    begin
        msg_view = dequeue_begin!(sub2)
        @test !isempty(msg_view)
        @test msg_view.size == size

        # get value from message
        value = unsafe_load(reinterpret(Ptr{Int64}, msg_view.data))
        @test value == 99

        dequeue_commit!(sub2, msg_view)
    end

    @test isempty(sub1)
    @test isempty(sub2)
    @test !can_dequeue(sub1)
    @test !can_dequeue(sub2)

    shm_unlink(pub_sub.publishers[1].shm)
    shm_unlink(pub_sub.publishers[2].shm)
end
