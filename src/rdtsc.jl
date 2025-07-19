@inline function rdtsc()::UInt64
    # https://github.com/m-j-w/CpuId.jl/blob/fd39b7b89755b9d7e69354f22fb81559f93d2e3a/src/CpuInstructions.jl#L80
    Base.llvmcall(
        """
        %1 = tail call { i32, i32 } asm sideeffect "rdtsc", "={ax},={dx},~{dirflag},~{fpsr},~{flags}"() #2
        %2 = extractvalue { i32, i32 } %1, 0
        %3 = extractvalue { i32, i32 } %1, 1
        %4 = zext i32 %2 to i64
        %5 = zext i32 %3 to i64
        %6 = shl nuw i64 %5, 32
        %7 = or i64 %6, %4
        ret i64 %7
        """,
        UInt64,
        Tuple{},
    )
end

"""
Measures the number of RDTSC cycles per nanosecond.
This measure is highly CPU/core specific and depends on power settings of
the machine. Use with caution.

Usually only needed for very low-latency / high throughput applications
measuring with nanosecond precision and low overhead.

Otherwise, consider using `get_clock_monotonic_ns` which is more portable
and reliable, or Julia's `time_ns`.

Example
-------

    t = ThreadPinning.@spawnat 1 measure_rdtsc_cycles_per_ns()
    cycles_per_ns = fetch(t)
    println("cycles per ns: \$cycles_per_ns")
"""
function measure_rdtsc_cycles_per_ns()::Float64
    # measure overhead of clock_gettime
    start_t = time_ns()
    for _ in 1:10_000
        time_ns()
    end
    end_t = time_ns()
    overhead_per_call = (end_t - start_t) / 10_000

    # warm-up phase
    for _ in 1:100
        rdtsc()
        time_ns()
    end

    # measure
    loops = 1001
    wait_time_ns = 10_000
    measurements = zeros(Float64, loops)
    for i in 1:loops
        start_cycles = rdtsc()
        start = time_ns()
        end_time = start + wait_time_ns
        while time_ns() < end_time
            # busy wait
        end
        end_cycles = rdtsc()
        measurements[i] = (end_cycles - start_cycles) / (wait_time_ns - overhead_per_call)
    end

    # get median value
    sort!(measurements)
    median_value = measurements[Int(ceil(loops / 2))]

    median_value
end
