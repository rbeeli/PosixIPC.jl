module Memory

using Base.Threads

const _ALIGNED_ALLOC_COUNTER = Atomic{Int64}(0)

"""
Allocates memory with a given alignment (power of 2) using `posix_memalign`.
The returned memory must be freed using `aligned_free` manually.

Note that allocating 0 bytes will return an error.

# References
linux.die.net/man/3/posix_memalign
"""
function aligned_alloc(alignment::Integer, size::Integer)::Ptr{Cvoid}
	size > 0 || throw(ArgumentError("size must be positive, got $size"))
	alignment > 0 || throw(ArgumentError("alignment must be positive, got $alignment"))
	ispow2(alignment) || throw(ArgumentError("alignment must be a power of 2, got $alignment"))
	alignment >= sizeof(Ptr{Cvoid}) || throw(ArgumentError("alignment must be at least $(sizeof(Ptr{Cvoid}))"))

	ptr_ref = Ref{Ptr{Cvoid}}()
	ret = ccall(:posix_memalign, Cint,
		(Ptr{Ptr{Cvoid}}, Csize_t, Csize_t),
		ptr_ref, Csize_t(alignment), Csize_t(size))

	ret == 0 || throw(OutOfMemoryError())

	# Get the actual pointer
	ptr = ptr_ref[]

	atomic_add!(_ALIGNED_ALLOC_COUNTER, 1)

	ptr
end

"""
Frees memory allocated by `aligned_alloc`.
"""
function aligned_free(ptr::Ptr{T})::Nothing where {T}
	ccall(:free, Cvoid, (Ptr{Cvoid},), ptr)
	atomic_sub!(_ALIGNED_ALLOC_COUNTER, 1)
	nothing
end

"""
Returns the number of aligned memory allocations not yet freed.
"""
aligned_alloc_count() = _ALIGNED_ALLOC_COUNTER[]

export aligned_alloc, aligned_free, aligned_alloc_count

end # module
