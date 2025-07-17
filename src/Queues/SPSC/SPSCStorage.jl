using PosixIPC.Memory

# Define the constant (you can look up this value in your system's unistd.h)
const _SC_LEVEL1_DCACHE_LINESIZE = 190
get_cache_line_size() = ccall((:sysconf,), Clong, (Cint,), _SC_LEVEL1_DCACHE_LINESIZE)

@assert get_cache_line_size() == 64 "System cache line size must be 64 bytes"

const SPSC_CACHE_LINE_SIZE::Base.Csize_t = 64       # bytes per cache line
const SPSC_MAGIC::UInt32 = 0x5350_5343       # 'S' 'P' 'S' 'C'
const SPSC_ABI_VERSION::UInt32 = 1                 # bump when layout changes
const SPSC_STORAGE_SIZE_OFFSET = 2 * sizeof(UInt32)
const SPSC_BUFFER_OFFSET::UInt64 = 4 * SPSC_CACHE_LINE_SIZE

"""
	SPSCStorage(storage_size::Integer)
	SPSCStorage(ptr::Ptr{T}, storage_size::Integer; finalizer_fn::Function)
	SPSCStorage(ptr::Ptr{T}; finalizer_fn::Function)

Encapsulates the memory storage for SPSC queues.

The storage has the following fixed, contiguous memory layout:

0   	magic   		(UInt32)
4   	abi_ver 		(UInt32)
8   	storage_size 	(UInt64)
16-63 	pad
64  	read_ix   		(UInt64)
128 	write_ix  		(UInt64)
192 	msg_count 		(UInt64)
256 	buffer

Pad is used to align the buffer to 64 bytes (cache line size).

This memory layout ensure cache line alignment for the read and write indices,
and can be used inside shared memory, e.g. as IPC mechanism to other languages (processes).

The struct is declared as mutable to ensure that the
finalizer is called by the GC when the object is no longer referenced.
An optional `finalizer_fn` function can be provided to perform additional cleanup
when the object is finalized by the GC, e.g. `free`ing  `malloc`ed memory.
"""
mutable struct SPSCStorage
	const magic::UInt32 # must equal SPSC_MAGIC
	const abi_version::UInt32 # must equal SPSC_ABI_VERSION
	const storage_size::UInt64
	const storage_ptr::Ptr{UInt8}
	const buffer_ptr::Ptr{UInt8}
	read_ix::Ptr{UInt64}
	write_ix::Ptr{UInt64}
	msg_count::Ptr{UInt64}

	"""
	Reads the SPSC storage data from an existing initialized memory region.
	"""
	function SPSCStorage(
		ptr::Ptr{T}
		;
		finalizer_fn::FFn = s -> nothing,
	) where {T, FFn <: Function}
		ptr == C_NULL && throw(ArgumentError("SPSCStorage mapping pointer is null"))

		if reinterpret(UInt, ptr) % 64 != 0
			throw(ArgumentError("SPSCStorage mapping memory address not 64-byte aligned"))
		end

		ptr8::Ptr{UInt8} = reinterpret(Ptr{UInt8}, ptr)
		storage_size::UInt64 = unsafe_load(reinterpret(Ptr{UInt64}, ptr8 + SPSC_STORAGE_SIZE_OFFSET))

		# verify SPSC_MAGIC
		magic = unsafe_load(reinterpret(Ptr{UInt32}, ptr8))
		if magic != SPSC_MAGIC
			throw(ErrorException("SPSCStorage bad SPSC_MAGIC"))
		end

		# verify SPSC_ABI_VERSION
		abi_version = unsafe_load(reinterpret(Ptr{UInt32}, ptr8 + sizeof(UInt32)))
		if abi_version != SPSC_ABI_VERSION
			throw(ErrorException("SPSCStorage ABI version mismatch"))
		end

		obj = new(
			SPSC_MAGIC,
			SPSC_ABI_VERSION,
			storage_size, # storage size
			ptr8, # storage_ptr
			ptr8 + SPSC_BUFFER_OFFSET, # buffer_ptr
			reinterpret(Ptr{UInt64}, ptr8 + SPSC_CACHE_LINE_SIZE * 1), # read_ix (0-based)
			reinterpret(Ptr{UInt64}, ptr8 + SPSC_CACHE_LINE_SIZE * 2), # write_ix (0-based)
			reinterpret(Ptr{UInt64}, ptr8 + SPSC_CACHE_LINE_SIZE * 3), # msg_count
		)

		# register finalizer to free memory on GC collection
		finalizer(finalizer_fn, obj)

		obj
	end

	"""
	Initializes new SPSC storage with the given memory region.

	Note that `storage_size` is the total size of the memory region, not just `buffer_size`.
	The total size is calculated as follows: `storage_size = SPSC_BUFFER_OFFSET + buffer_size`.
	"""
	function SPSCStorage(
		ptr::Ptr{T},
		storage_size::Integer
		;
		finalizer_fn::FFn = s -> nothing,
	) where {T, FFn <: Function}
		ptr::Ptr{UInt8} = reinterpret(Ptr{UInt8}, ptr)

		if storage_size <= SPSC_BUFFER_OFFSET
			throw(ArgumentError(
				"SPSCStorage requires a memory region greater than $SPSC_BUFFER_OFFSET bytes, " *
				"requested size of $storage_size bytes is too small.",
			))
		end

		# write storage metadata to memory region
		storage_write_metadata!(
			SPSCStorage,
			ptr,
			UInt64(storage_size),
			UInt64(0), # read_ix
			UInt64(0), # write_ix
			UInt64(0), # msg_count
		)

		SPSCStorage(ptr, finalizer_fn = finalizer_fn)
	end

	"""
	Initializes new SPSC storage with given storage size.

	Note that `storage_size` is the total size of the memory region, not just `buffer_size`.
	The total size is calculated as follows: `storage_size = SPSC_BUFFER_OFFSET + buffer_size`.
	"""
	SPSCStorage(storage_size::Integer) = begin
		# allocate heap memory for storage (aligned to cache line size)
		ptr::Ptr{UInt8} = aligned_alloc(SPSC_CACHE_LINE_SIZE, storage_size)

		if storage_size <= SPSC_BUFFER_OFFSET
			throw(ArgumentError(
				"SPSCStorage requires a memory region greater than $SPSC_BUFFER_OFFSET bytes, " *
				"requested size of $storage_size bytes is too small.",
			))
		end

		# write storage metadata to memory region
		storage_write_metadata!(
			SPSCStorage,
			ptr,
			UInt64(storage_size),
			UInt64(0), # read_ix
			UInt64(0), # write_ix
			UInt64(0) # msg_count
		)

		SPSCStorage(ptr; finalizer_fn = x -> aligned_free(x.storage_ptr))
	end
end

@inline buffer_size(storage::SPSCStorage)::UInt64 = storage.storage_size - SPSC_BUFFER_OFFSET

function storage_write_metadata!(
	::Type{SPSCStorage},
	storage_ptr::Ptr{UInt8},
	storage_size::UInt64,
	read_ix::UInt64,
	write_ix::UInt64,
	msg_count::UInt64,
)::Nothing
	# write storage metadata to memory
	unsafe_store!(reinterpret(Ptr{UInt32}, storage_ptr), SPSC_MAGIC)
	unsafe_store!(reinterpret(Ptr{UInt32}, storage_ptr + sizeof(UInt32)), SPSC_ABI_VERSION)
	unsafe_store!(reinterpret(Ptr{UInt64}, storage_ptr + SPSC_STORAGE_SIZE_OFFSET), storage_size)
	unsafe_store!(reinterpret(Ptr{UInt64}, storage_ptr + SPSC_CACHE_LINE_SIZE * 1), read_ix, :release) # read_ix (0-based)
	unsafe_store!(reinterpret(Ptr{UInt64}, storage_ptr + SPSC_CACHE_LINE_SIZE * 2), write_ix, :release) # write_ix (0-based)
	unsafe_store!(reinterpret(Ptr{UInt64}, storage_ptr + SPSC_CACHE_LINE_SIZE * 3), msg_count, :release) # msg_count
	nothing
end
