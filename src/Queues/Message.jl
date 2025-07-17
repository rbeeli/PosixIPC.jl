struct Message
	size::UInt64
	data::Ptr{UInt8}

	function Message(data::Ptr{T}, size::TSize) where {T, TSize <: Integer}
		new(UInt64(size), reinterpret(Ptr{UInt8}, data))
	end
end
@inline total_size(msg::Message)::UInt64 = sizeof(UInt64) + msg.size
@inline payload_size(msg::Message)::UInt64 = msg.size


"""
	MessageView

A lightweight view (zero-copy) into a message in the SPSC queue.

The underlying memory can be accessed and modified through the `data` field
until `dequeue_commit!` is called.

The `size` field contains the size of the message in bytes.

The `index` field contains the 0-based index of the message in the queue's buffer.
"""
struct MessageView
	size::UInt64
	data::Ptr{UInt8}
	index::UInt64
end
const SPSC_MESSAGE_VIEW_EMPTY::MessageView = MessageView(0, C_NULL, 0);

"""
	isempty(view::MessageView) -> Bool

Returns `true` if the message view is empty (size is 0), implying that the queue is empty.
"""
@inline Base.isempty(view::MessageView)::Bool = view.size == 0
