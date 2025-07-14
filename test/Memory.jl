using TestItems

@testitem "Basic Allocation/Deallocation" begin
    import PosixIPC.Memory
    
    count_start = Memory.aligned_alloc_count()

    # Test single allocation
    ptr = Memory.aligned_alloc(64, 32)
    @test ptr != C_NULL
    @test Memory.aligned_alloc_count() - count_start == 1
    Memory.aligned_free(ptr)
    @test Memory.aligned_alloc_count() - count_start == 0
end

@testitem "Alignment Requirements" begin
    import PosixIPC.Memory

    # Test different alignments (power of 2)
    for align in [8, 16, 32, 64, 128]
        ptr = Memory.aligned_alloc(64, align)
        # Test if pointer is properly aligned
        @test UInt(ptr) % align == 0
        Memory.aligned_free(ptr)
    end
end

@testitem "Thread Safety" begin
    import PosixIPC.Memory

    n_threads = 4
    n_allocs_per_thread = 100
    
    count_start = Memory.aligned_alloc_count()

    function worker()
        ptrs = Vector{Ptr{Cvoid}}()
        for i in 1:n_allocs_per_thread
            push!(ptrs, Memory.aligned_alloc(64, 32))
        end
        for ptr in ptrs
            Memory.aligned_free(ptr)
        end
    end

    tasks = [Threads.@spawn worker() for _ in 1:n_threads]
    foreach(wait, tasks)
    
    @test Memory.aligned_alloc_count() - count_start == 0
end

@testitem "Error Conditions" begin
    import PosixIPC.Memory
    
    # Test zero size allocation
    @test_throws ArgumentError Memory.aligned_alloc(0, 32)
    
    # Test invalid alignment (not power of 2)
    @test_throws ArgumentError Memory.aligned_alloc(64, 33)
    
    # Test alignment smaller than sizeof(void*)
    @test_throws ArgumentError Memory.aligned_alloc(64, 1)

    # Test zero size
    @test_throws ArgumentError Memory.aligned_alloc(0, 8)
    
    # Test negative size
    @test_throws ArgumentError Memory.aligned_alloc(-64, 8)
    
    # Test negative alignment
    @test_throws ArgumentError Memory.aligned_alloc(64, -8)
end
