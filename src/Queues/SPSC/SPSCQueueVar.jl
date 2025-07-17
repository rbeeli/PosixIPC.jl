using ..Queues: Message, MessageView, total_size, payload_size, SPSC_MESSAGE_VIEW_EMPTY
import ..Queues
using ...Queues: can_dequeue, dequeue_begin!, dequeue_commit!, isempty

"""
A Single-Producer Single-Consumer (SPSC) queue with variable-sized message buffer.
"""
mutable struct SPSCQueueVar
	const storage::SPSCStorage
	const max_message_size::UInt64  # max size single message in bytes (including header bytes)
	const buffer_size::UInt64

	function SPSCQueueVar(storage::SPSCStorage)
		buf_size = buffer_size(storage)

		# ensure buffer size is divisible by 8
		if buf_size % 8 != 0
			throw(ArgumentError("Storage buffer size must be divisible by 8, got value $buf_size."))
		end

        # ensure can store at least 1 byte
        min_required = next_index(0, sizeof(UInt64) + 8)
		if buf_size < min_required
			throw(ArgumentError("SPSCQueueVar buffer too small"))
		end

		new(
			storage,
			calc_max_message_size(storage),
			buf_size,
		)
	end
end

"""
Calculates the maximum allowed message size given the overall storage buffer size.
Message size here includes the size header value.

At least two messages must fit in buffer, otherwise we can't
distinguish between empty and full, because the updated write index
will be equal to the read index (0) after the first message
has been written due to wrapping around, falsely indicating that
the queue is empty.
"""
@inline calc_max_message_size(storage::SPSCStorage) = div(buffer_size(storage), 2)

"""
Returns `true` if the SPSC queue is empty.
Does not dequeue any messages (read-only operation).

There is no guarantee that the queue is still empty after this function returns,
as the writer might have enqueued a message immediately after the check.
"""
@inline function Base.isempty(queue::SPSCQueueVar)::Bool
	unsafe_load(queue.storage.read_ix, :acquire) == unsafe_load(queue.storage.write_ix, :acquire)
end

"""
Returns the number of messages currently in the SPSC queue.

* **Reader thread:** value is a *lower bound* (≥ actual messages).
* **Writer thread:** value is an *upper bound* (≤ actual messages).

No guarantee the value is still current once this function returns,
because the peer thread may act in parallel.
"""
@inline function Base.length(queue::SPSCQueueVar)::Int
	unsafe_load(queue.storage.msg_count, :acquire)
end

"""
Returns `false` if the SPSC queue is empty.
Does not dequeue any messages (read-only operation).

To be used by consumer thread only due to memory order optimization.
"""
@inline function Queues.can_dequeue(queue::SPSCQueueVar)::Bool
	unsafe_load(queue.storage.read_ix, :monotonic) ≠ unsafe_load(queue.storage.write_ix, :acquire)
end

@inline buffer_size(queue::SPSCQueueVar) = queue.buffer_size

@inline max_message_size(queue::SPSCQueueVar) = queue.max_message_size

@inline max_payload_size(queue::SPSCQueueVar) = queue.max_message_size - sizeof(UInt64)

"""
Enqueues a message in the queue. Returns `true` if successful, `false` if the queue is full.
"""
@inline function Queues.enqueue!(queue::SPSCQueueVar, msg::Message)::Bool
	@assert payload_size(msg) > 0 "Message payload size must be greater than 0 bytes"
	@assert payload_size(msg) ≤ max_payload_size(queue) "Message payload too large"

	# current writer position (relaxed load)
	read_ix::UInt64       = unsafe_load(queue.storage.read_ix, :acquire)
	write_ix::UInt64      = unsafe_load(queue.storage.write_ix, :monotonic)
	total_size_::UInt64   = total_size(msg)
	next_write_ix::UInt64 = next_index(write_ix, total_size_)

	if next_write_ix < queue.buffer_size
		# not crossing the end

		# check if we would cross the reader
		if write_ix < read_ix && next_write_ix ≥ read_ix
			return false   # queue full
		end

		# copy payload + header
		unsafe_copyto!(queue.storage.buffer_ptr + write_ix + sizeof(UInt64),
			msg.data, payload_size(msg))
		unsafe_store!(reinterpret(Ptr{UInt64}, queue.storage.buffer_ptr + write_ix),
			UInt64(payload_size(msg)))
	else
		# crossing the end

		# check if space for writing 8 byte sentinal value (size=0)
		sentinel_end::UInt64 = write_ix + UInt64(sizeof(UInt64))
		if write_ix < read_ix && sentinel_end ≥ read_ix
			return false   # reader inside sentinel
		end

		# check if space for payload (on cache first, then update if needed)
		next_write_ix = next_index(UInt64(0), total_size_)
		if next_write_ix ≥ read_ix
			return false   # queue full after wrap
		end

		# copy payload + header to start of buffer
		unsafe_copyto!(queue.storage.buffer_ptr + sizeof(UInt64),
			msg.data, payload_size(msg))
		unsafe_store!(reinterpret(Ptr{UInt64}, queue.storage.buffer_ptr),
			UInt64(payload_size(msg)))

		# write 0 size sentinel at current write_ix to indicate wrap
		unsafe_store!(reinterpret(Ptr{UInt64}, queue.storage.buffer_ptr + write_ix), UInt64(0))
	end

	# update writer head
	unsafe_store!(queue.storage.write_ix, next_write_ix, :release)

	# increment message counter
	unsafe_modify!(queue.storage.msg_count, +, 1, :acquire_release)

	true   # success
end


"""
Reads the next message from the queue.
Returns a message view with `size = 0` if the queue is empty (`SPSC_MESSAGE_VIEW_EMPTY`).
Call `isempty(msg)` to check if a message was dequeued successfully.

The reader only advances after calling `dequeue_commit!`, this allows to use the
message view without copying the data to another buffer between `dequeue_begin!` and `dequeue_commit!`.

Failing to call `dequeue_commit!` is allowed, but means the reader will not advance.
"""
@inline function Queues.dequeue_begin!(queue::SPSCQueueVar)::MessageView
	@label recheck_read_index
	read_ix::UInt64 = unsafe_load(queue.storage.read_ix, :monotonic)
	write_ix::UInt64 = unsafe_load(queue.storage.write_ix, :acquire)

	# check if queue is empty
	if read_ix == write_ix
		return SPSC_MESSAGE_VIEW_EMPTY  # queue is empty
	end

	# read message size
	message_size::UInt64 = unsafe_load(reinterpret(Ptr{UInt64}, queue.storage.buffer_ptr + read_ix))
	if message_size == 0 # wrap-around sentinel
		# message wraps around, move to beginning of queue
		unsafe_store!(queue.storage.read_ix, UInt64(0), :release) # 0-based indexing
		@goto recheck_read_index
	end

	# read message
	data::Ptr{UInt8} = reinterpret(Ptr{UInt8}, queue.storage.buffer_ptr + read_ix + 8)
	msg = MessageView(message_size, data, read_ix)
	msg
end

"""
Moves the reader index to the next message in the queue.
Call this after processing a message returned by `dequeue_begin!`.
The `MessageView`` is no longer valid after this call.
"""
@inline function Queues.dequeue_commit!(queue::SPSCQueueVar, msg::MessageView)::Nothing
	# advance reader index
	next_read_ix = next_index(msg.index, msg.size + 8)
	unsafe_store!(queue.storage.read_ix, next_read_ix, :release)

	# decrement message counter
	unsafe_modify!(queue.storage.msg_count, -, 1, :acquire_release)

	nothing
end

"""
Calculates where the next write index would be given
writing a message of size `size` at the current index.

The index is aligned to 8 bytes.
If the requested size is not divisible by 8, the next
8 bytes divisible index is used.
"""
@inline function next_index(current_index, size)
	align = 8
	ix = current_index + size
	# round up to the next multiple of align (8 bytes)
	(ix + align - 1) & ~(align - 1)
end
